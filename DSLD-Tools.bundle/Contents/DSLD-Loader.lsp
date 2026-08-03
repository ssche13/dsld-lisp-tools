;;; ===================================================================
;;; DSLD-Loader.lsp - auto-loads the DSLD office LISP tools
;;;
;;; Part of DSLD-Tools.bundle.  AutoCAD's plug-in AutoLoader runs this
;;; file in every drawing (same behavior as the Startup Suite), which
;;; in turn loads the three routines that live next to it:
;;;
;;;   roof-pitch-rafters.lsp   RPR...   roof pitch / rafters / chart
;;;   SCH.lsp                  SCH...   schedule of openings auto-fill
;;;   ADIM.lsp                 ADIM...  automatic plan dimensioning
;;;
;;; Commands added by this loader:
;;;   DSLDUPDATE - download the latest copy of all three from GitHub
;;;                into the bundle (old copies kept as .bak), reload
;;;   DSLDRELOAD - re-load the three files from disk without a restart
;;;
;;; Distribution repo: https://github.com/ssche13/dsld-lisp-tools
;;; ===================================================================
(vl-load-com)

(setq *dsld:bundle-version* "1.0.0")
(setq *dsld:raw-base*
  "https://raw.githubusercontent.com/ssche13/dsld-lisp-tools/main/DSLD-Tools.bundle/Contents/")
(setq *dsld:files* '("roof-pitch-rafters.lsp" "SCH.lsp" "ADIM.lsp"))

;; The bundle's Contents folder: per-user install first, then the
;; all-users location.  nil when neither exists.
(defun dsld:dir ( / tail a p cands hit)
  (setq tail "\\Autodesk\\ApplicationPlugins\\DSLD-Tools.bundle\\Contents")
  (setq a (getenv "APPDATA")
        p (getenv "PROGRAMDATA"))
  (if a (setq cands (list (strcat a tail))))
  (if p (setq cands (append cands (list (strcat p tail)))))
  (foreach d cands (if (and (null hit) (vl-file-directory-p d)) (setq hit d)))
  hit)

;; Put the bundle folder FIRST on the saved support search path so the
;; findfile-based self-updaters (RPRUPDATE and its load-time check,
;; SCHUPDATE) always resolve the BUNDLE copies - never a dev copy that
;; may sit elsewhere on the path.  Fail-soft: skipped silently where
;; the COM preferences object is unavailable (accoreconsole).
(defun dsld:ensure-support-path (dir)
  (vl-catch-all-apply
    (function
      (lambda ( / files sp)
        (setq files (vla-get-Files
                      (vla-get-Preferences (vlax-get-acad-object))))
        (setq sp (vla-get-SupportPath files))
        (if (null (vl-string-search (strcase dir) (strcase sp)))
          (vla-put-SupportPath files (strcat dir ";" sp)))))
    nil))

;; Load one file from the bundle; nil on success, an error string on
;; failure so the caller can report every problem in one message.
(defun dsld:load1 (dir name / p r)
  (setq p (strcat dir "\\" name))
  (cond
    ((null (findfile p)) (strcat name " missing"))
    (t
     (setq r (vl-catch-all-apply 'load (list p)))
     (if (vl-catch-all-error-p r)
       (strcat name ": " (vl-catch-all-error-message r))))))

(defun dsld:load-all ( / dir errs e)
  (setq dir (dsld:dir))
  (cond
    ((null dir)
     (princ "\n[DSLD] DSLD-Tools.bundle not found under ApplicationPlugins - nothing loaded."))
    (t
     (dsld:ensure-support-path dir)
     (foreach name *dsld:files*
       (if (setq e (dsld:load1 dir name)) (setq errs (cons e errs))))
     ;; SCH.lsp resets *sch:home* to its dev path on every load; point
     ;; its self-updater at the copy that is actually running.
     (setq *sch:home* (strcat dir "\\SCH.lsp"))
     (if errs
       (progn
         (princ "\n[DSLD] Load problems:")
         (foreach e (reverse errs) (princ (strcat "\n  " e))))
       (princ (strcat "\n[DSLD] Tools bundle v" *dsld:bundle-version*
                      " - RPR / SCH / ADIM loaded.  DSLDUPDATE pulls the latest.")))))
  (princ))

;; GET url -> body string on HTTP 200, nil otherwise.  Tight timeouts
;; so a dead network can never hang CAD.
(defun dsld:http-get (url / xml body)
  (vl-catch-all-apply
    (function
      (lambda ( )
        (setq xml (vlax-create-object "WinHttp.WinHttpRequest.5.1"))
        (vlax-invoke-method xml 'SetTimeouts 2000 2000 2000 8000)
        (vlax-invoke-method xml 'Open "GET" url :vlax-false)
        (vlax-invoke-method xml 'Send)
        (if (= 200 (vlax-get-property xml 'Status))
          (setq body (vlax-get-property xml 'ResponseText)))))
    nil)
  (if xml (vl-catch-all-apply 'vlax-release-object (list xml)))
  body)

;; Slurp a file with line endings normalized to "\n" - matches what
;; GitHub raw returns, so unchanged files compare equal.
(defun dsld:read-file (path / f line s)
  (setq s "")
  (if (setq f (open path "r"))
    (progn
      (while (setq line (read-line f)) (setq s (strcat s line "\n")))
      (close f)))
  s)

(defun dsld:write-file (path s / f)
  (if (setq f (open path "w"))
    (progn (princ s f) (close f) T)))

(defun c:DSLDUPDATE ( / dir p body n-new n-same n-fail)
  (setq n-new 0 n-same 0 n-fail 0)
  (setq dir (dsld:dir))
  (cond
    ((null dir) (princ "\n[DSLD] Bundle folder not found."))
    (t
     (foreach name *dsld:files*
       (setq p (strcat dir "\\" name))
       (princ (strcat "\n[DSLD] " name " ... "))
       (setq body (dsld:http-get (strcat *dsld:raw-base* name)))
       (cond
         ;; sanity: a real routine is big and defines commands - never
         ;; overwrite with an error page or a truncated download
         ((or (null body) (< (strlen body) 2000)
              (null (vl-string-search "(defun" body)))
          (princ "FETCH FAILED (no internet / GitHub unreachable?)")
          (setq n-fail (1+ n-fail)))
         ((equal (dsld:read-file p) body)
          (princ "already up to date")
          (setq n-same (1+ n-same)))
         (t
          (vl-catch-all-apply 'vl-file-delete (list (strcat p ".bak")))
          (vl-catch-all-apply 'vl-file-copy (list p (strcat p ".bak")))
          (cond
            ((dsld:write-file p body)
             (princ "UPDATED (old copy kept as .bak)")
             (setq n-new (1+ n-new)))
            (t
             (princ "write failed (file locked?)")
             (setq n-fail (1+ n-fail)))))))
     (if (> n-new 0) (dsld:load-all))
     (princ (strcat "\n[DSLD] Update done: " (itoa n-new) " updated, "
                    (itoa n-same) " current, " (itoa n-fail) " failed."))
     (if (> n-new 0)
       (princ "\n[DSLD] New code is live in THIS drawing; reopen other drawings to pick it up."))))
  (princ))

(defun c:DSLDRELOAD ( ) (dsld:load-all))

;; run at load time - the AutoLoader executes this file in each drawing
(dsld:load-all)
