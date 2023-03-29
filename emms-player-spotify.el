;;; emms-player-spotify.el --- Spotify player for EMMS  -*- lexical-binding: t; -*-

;; Copyright (C) 2023 by Sergey Trofimov

;; Author: Sergey Trofimov <sarg@sarg.org.ru>
;; Version: 0.1
;; URL: https://github.com/sarg/emms-spotify.el
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; This package displays torrent files using tablist-mode.

;;; Code:
(require 's)
(require 'dbus)
(require 'url-parse)
(require 'emms)
(require 'emms-playing-time)
(require 'emms-playlist-mode)
(require 'emms-source-file)
(require 'seq)

(defcustom emms-player-spotify
  (emms-player
   #'emms-player-spotify-start
   #'emms-player-spotify-stop
   #'emms-player-spotify-playable-p)
  "*Parameters for spotify player."
  :type '(cons symbol alist)
  :group 'emms-player-spotify)

;;; Utils

(defun seconds-to-millis (sec)
  (* sec (expt 10 6)))

(defun millis-to-seconds (ms)
  (round (* ms (expt 10 -6))))

(defun emms-player-spotify--transform-url (url)
  (or (and (string-prefix-p "https" url)
        (concat "spotify"
          (replace-regexp-in-string
            "/" ":"
            (car (url-path-and-query (url-generic-parse-url url))))))
    url))

;;; adblock

(defun emms-player-spotify--set-volume (val)
  "Set spotify volume to VAL over MPRIS."
  (dbus-set-property
   :session
   "org.mpris.MediaPlayer2.spotify"
   "/org/mpris/MediaPlayer2"
   "org.mpris.MediaPlayer2.Player"
   "Volume"
   (float val)))

(defun emms-player-spotify--adblock-do (is-ad)
  "Mute spotify depending on IS-AD."
  (if is-ad (emms-player-spotify--set-volume 0)
    (run-with-timer 2 nil #'emms-player-spotify--set-volume 1)))

(define-minor-mode emms-player-spotify-adblock
  "Mutes spotify ads."
  :require 'emms-player-spotify
  :global t)

;;; DBUS events handler

(defun emms-player-spotify--update-metadata (metadata)
  "Update current EMMS track with METADATA."
  (let* ((album   (caadr  (assoc "xesam:album"  metadata)))
         (length  (caadr  (assoc "mpris:length" metadata)))
         (artist  (caaadr (assoc "xesam:artist" metadata)))
         (title   (caadr  (assoc "xesam:title"  metadata)))
         (url     (caadr  (assoc "xesam:url"    metadata)))
         (trackid (emms-player-spotify--transform-url url)))

    (when-let* (((eq emms-player-playing-p emms-player-spotify))
                (current-track (emms-playlist-current-selected-track))
                ((equal (emms-track-name current-track) trackid)))
      (emms-track-set current-track 'info-artist artist)
      (emms-track-set current-track 'info-album album)
      (emms-track-set current-track 'info-title title)
      (emms-track-set current-track 'info-playing-time (millis-to-seconds length))
      (emms-track-updated current-track))))

(defun emms-player-spotify--event-handler (_ properties &rest _)
  "Handles mpris dbus event.
Extracts playback status and track metadata from PROPERTIES."
  (let* ((metadata (caadr (assoc "Metadata" properties)))
         (playback-status
          (or (caadr (assoc "PlaybackStatus" properties))
              (and metadata "Playing"))))

    (pcase playback-status
      ;; play pressed outside of emms
      ((and "Playing" (guard emms-player-paused-p))
       (setq emms-player-paused-p nil)
       (run-hooks 'emms-player-paused-hook))

      ;; resumed after emms-playpause request
      ((and "Playing" (guard (emms-player-get emms-player-spotify 'playpause-requested)))
       (emms-player-set emms-player-spotify 'playpause-requested nil)
       (ignore))

      ;; new track reported via mpris
      ("Playing"
       (with-current-emms-playlist
         (let* ((metadata (or metadata (emms-player-spotify--get-mpris-metadata)))
                (url (caadr (assoc "xesam:url" metadata)))
                (new-track (emms-player-spotify--transform-url url))
                (new-is-ad (s-prefix-p "spotify:ad" new-track))
                (cur-track (emms-playlist-selected-track))
                (cur-is-ad (s-prefix-p "spotify:ad" (emms-track-name cur-track))))

           ;; adblock maybe
           (when emms-player-spotify-adblock
             (emms-player-spotify--adblock-do new-is-ad))

           ;; override artist and title for ads
           (when new-is-ad
             (setf (alist-get "xesam:artist" metadata nil nil #'equal)
                   '((("Spotify")))

                   (alist-get "xesam:title" metadata nil nil #'equal)
                   '(("Ads"))))

           (cond
            ;; subsequent ad, ignore
            ((and new-is-ad cur-is-ad)
             (ignore))

            ;; first ad track, add a placeholder
            (new-is-ad
             (emms-player-spotify-following--on-new-track new-track))

            ;; following mode, add the track
            (emms-player-spotify-following
             (emms-player-spotify-following--on-new-track new-track)

             (when cur-is-ad
               ;; last ad track, remove placeholder
               (save-excursion
                 (goto-char emms-playlist-selected-marker)
                 (forward-line -1)
                 (emms-playlist-mode-kill-entire-track)))))

           (emms-player-spotify--update-metadata metadata))))

      ((and "Paused" (guard (emms-player-get emms-player-spotify 'playpause-requested)))
       (emms-player-set emms-player-spotify 'playpause-requested nil)
       (ignore))

      ((and "Paused" (guard (emms-player-get emms-player-spotify 'stop-requested)))
       ;; special case, when user changes track in emms
       ;; emms-player-spotify-stop called
       ;; mpris Stop called
       ;; emms-player-spotify-start called
       ;; Paused mpris event comes
       (emms-player-set emms-player-spotify 'stop-requested nil)
       (ignore))

      ("Paused"
       ;; pause pressed in spotify or the song ended
       (let* ((current-track (emms-playlist-current-selected-track))
              (track-len (emms-track-get current-track 'info-playing-time))
              (song-ended (< (- track-len emms-playing-time) 2))
              (is-ad (s-prefix-p "spotify:ad" (emms-track-name current-track))))

         (cond
          (is-ad
           (with-current-emms-playlist
             (save-excursion
               (goto-char emms-playlist-selected-marker)
               (emms-player-stopped)
               (emms-playlist-mode-kill-entire-track))))

          (song-ended
           (emms-player-stopped))

          ('paused-externally
           (setq emms-player-paused-p t)
           (run-hooks 'emms-player-paused-hook))))))))

(defun emms-player-spotify--get-mpris-metadata ()
  (cdr (assoc "Metadata"
         (dbus-get-all-properties :session
           "org.mpris.MediaPlayer2.spotify"
           "/org/mpris/MediaPlayer2"
           "org.mpris.MediaPlayer2.Player"))))

(defmacro emms-player-spotify--dbus-call (method &rest args)
  `(dbus-call-method-asynchronously :session
     "org.mpris.MediaPlayer2.spotify"
     "/org/mpris/MediaPlayer2"
     "org.mpris.MediaPlayer2.Player"
     ,method
     nil
     ,@(if args args '())))

(defun emms-player-spotify-disable-dbus-handler ()
  (dbus-unregister-object (emms-player-get emms-player-spotify 'dbus-handler))
  (dbus-unregister-object (emms-player-get emms-player-spotify 'dbus-seek-handler)))

(defun emms-player-spotify--seek-handler (pos)
  "Set current playing time to POS when Seeked event occurs."
  (emms-playing-time-set (millis-to-seconds pos)))

(defun emms-player-spotify-enable-dbus-handler ()
  (unless (member "org.mpris.MediaPlayer2.spotify" (dbus-list-known-names :session))
   (error "Spotify App is not running"))

  (emms-player-set emms-player-spotify
    'dbus-seek-handler
    (dbus-register-signal :session
      "org.mpris.MediaPlayer2.spotify"
      "/org/mpris/MediaPlayer2"
      "org.mpris.MediaPlayer2.Player"
      "Seeked"
      #'emms-player-spotify--seek-handler))

  (emms-player-set emms-player-spotify
    'dbus-handler
    (dbus-register-signal :session
      "org.mpris.MediaPlayer2.spotify"
      "/org/mpris/MediaPlayer2"
      "org.freedesktop.DBus.Properties"
      "PropertiesChanged"
      (lambda (&rest args)
        (when (eq emms-player-playing-p emms-player-spotify)
          (apply #'emms-player-spotify--event-handler args))))))

;;; Following mode

(defun emms-player-spotify-following-next ()
  "Call spotify next."
  (emms-player-spotify--dbus-call "Next"))

(defun emms-player-spotify-following-previous ()
  "Call spotify previous."
  (emms-player-spotify--dbus-call "Previous"))

(defun emms-player-spotify-following--on-new-track (new-track)
  "Insert EMMS track with metadata from NEW-TRACK."
  (save-excursion
    ;; create new entry with current track from the radio
    (goto-char emms-playlist-selected-marker)
    (emms-with-inhibit-read-only-t
     (let ((url (emms-track-name (emms-playlist-track-at))))
       (when (or (s-prefix-p "spotify:track" url)
                 (s-prefix-p "spotify:ad" url))
         (forward-line)))

     (emms-insert-url new-track)
     (forward-line -1)
     (set-marker emms-playlist-selected-marker (point))
     (emms-player-started emms-player-spotify))))

(define-minor-mode emms-player-spotify-following
  "When playing radios keep history in the same playlist."
  :global nil

  (cond
   (emms-player-spotify-following
    (advice-add 'emms-next :override #'emms-player-spotify-following-next)
    (advice-add 'emms-previous :override #'emms-player-spotify-following-previous))
   (t
    (advice-remove 'emms-next #'emms-player-spotify-following-next)
    (advice-remove 'emms-previous #'emms-player-spotify-following-previous))))

;;; emms interface

(defun emms-player-spotify-start (track)
  (emms-player-spotify-enable-dbus-handler)
  (let ((url (emms-player-spotify--transform-url (emms-track-name track))))

    (unless (string= "track" (nth 1 (split-string url ":")))
      (emms-player-spotify-following t))

    (emms-player-spotify--dbus-call "OpenUri" url))
  (emms-player-started emms-player-spotify))

(defun emms-player-spotify-stop ()
  (emms-player-spotify-following -1)
  (emms-player-stopped)
  (emms-player-set emms-player-spotify 'stop-requested t)
  (emms-player-spotify--dbus-call "Stop"))

(defun emms-player-spotify-play ()
  "Start playing current track in spotify."
  (interactive)
  (emms-player-set emms-player-spotify 'playpause-requested t)
  (emms-player-spotify--dbus-call "Play"))

(defun emms-player-spotify-seek (sec)
  "Seek to SEC relatively."
  (interactive)

  (emms-player-spotify--dbus-call "Seek" :int64 (seconds-to-millis sec)))

(defun emms-player-spotify-seek-to (sec)
  "Seek to absolute position SEC."
  (interactive)

  (with-current-emms-playlist
    (let* ((track (emms-playlist-current-selected-track))
           (name (emms-track-name track))
           (trackid (concat "/com/" (s-replace ":" "/" name))))

      (emms-player-spotify--dbus-call
       "SetPosition" :object-path trackid :int64 (seconds-to-millis sec)))))

(defun emms-player-spotify-pause ()
  "Pause current track in spotify."
  (interactive)
  (emms-player-set emms-player-spotify 'playpause-requested t)
  (emms-player-spotify--dbus-call "Pause"))

(defun emms-player-spotify-playable-p (track)
  (and (memq (emms-track-type track) '(url))
    (string-match-p (emms-player-get emms-player-spotify 'regex) (emms-track-name track))))

(emms-player-set emms-player-spotify 'regex
                 (rx string-start (or "https://open.spotify.com" "spotify:")))
(emms-player-set emms-player-spotify 'pause #'emms-player-spotify-pause)
(emms-player-set emms-player-spotify 'resume #'emms-player-spotify-play)
(emms-player-set emms-player-spotify 'seek #'emms-player-spotify-seek)
(emms-player-set emms-player-spotify 'seek-to #'emms-player-spotify-seek-to)

(provide 'emms-player-spotify)
;;; emms-player-spotify.el ends here
