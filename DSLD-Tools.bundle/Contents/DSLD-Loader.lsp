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

(setq *dsld:bundle-version* "1.1.3")
(setq *dsld:raw-base*
  "https://raw.githubusercontent.com/ssche13/dsld-lisp-tools/main/DSLD-Tools.bundle/Contents/")
(setq *dsld:files* '("roof-pitch-rafters.lsp" "SCH.lsp" "ADIM.lsp"))
;; binary payloads (SchTagNet .NET schedule-tag add-in) - fetched
;; byte-exact, never through the text path
(setq *dsld:binfiles*
  '("SchTagNet.dll" "SchTagNet.deps.json" "SchTagNet.runtimeconfig.json"))

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

;; Add one folder to TRUSTEDPATHS unless an entry already covers it.
;; Root must be added BEFORE Contents: the root path is a substring of
;; the Contents path, so the idempotency check stays correct.
(defun dsld:trust-dir (dir / tp)
  (setq tp (getvar "TRUSTEDPATHS"))
  (if (null tp) (setq tp ""))
  (if (null (vl-string-search (strcase dir) (strcase tp)))
    (setvar "TRUSTEDPATHS" (if (= tp "") dir (strcat tp ";" dir)))))

;; Register the bundle with SECURELOAD so the per-drawing loads never
;; raise the security prompt.  TRUSTEDPATHS entries do not cover
;; subfolders, so the bundle root and Contents both go in.  Persisted
;; in the profile - after this runs once, every later session is
;; prompt-free.  Fail-soft where the sysvar is absent (accoreconsole).
(defun dsld:ensure-trusted (dir)
  (vl-catch-all-apply
    (function
      (lambda ( )
        (dsld:trust-dir (vl-filename-directory dir))
        (dsld:trust-dir dir)))
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

(defun dsld:slash (s) (vl-string-translate "\\" "/" s))

;; the acaddoc.lsp already on the support search path, else a fresh
;; one under the roamable Support folder (same resolution SCHINSTALL
;; used, so both mechanisms always act on the SAME file)
(defun dsld:acaddoc-target ( / tgt dir)
  (setq tgt (findfile "acaddoc.lsp"))
  (if (null tgt)
    (progn
      (setq dir (strcat (getvar "ROAMABLEROOTPREFIX") "Support"))
      (vl-mkdir dir)
      (setq tgt (strcat dir "\\acaddoc.lsp"))))
  tgt)

;; Guarantee per-drawing loading via acaddoc.lsp, which AutoCAD loads
;; in EVERY document.  The plug-in AutoLoader is only reliable for
;; LISP once at startup - on some machines the tools appeared in the
;; first session and vanished after a restart.  Marker-based and
;; self-repairing: stale or duplicate entries are collapsed to exactly
;; one absolute-path, findfile-guarded load line.  No-op (not even a
;; write) when the file is already correct.
(defun dsld:ensure-acaddoc-hook (dir)
  (vl-catch-all-apply
    (function
      (lambda ( / tgt mark loadline f line lines out skipnext)
        (setq tgt  (dsld:acaddoc-target)
              mark ";; DSLD-AUTOLOAD (added by DSLD-Tools; loads the tools in every drawing)"
              loadline (strcat "(if (findfile \"" (dsld:slash dir)
                               "/DSLD-Loader.lsp\") (load \""
                               (dsld:slash dir) "/DSLD-Loader.lsp\" nil))"))
        (if (setq f (open tgt "r"))
          (progn (while (setq line (read-line f))
                   (setq lines (cons line lines)))
                 (close f)))
        (setq lines (reverse lines))
        (foreach line lines
          (cond
            (skipnext (setq skipnext nil))
            ((wcmatch line "*DSLD-AUTOLOAD*") (setq skipnext T))
            (t (setq out (cons line out)))))
        (setq out (reverse out))
        (if (not (equal lines (append out (list mark loadline))))
          (if (setq f (open tgt "w"))
            (progn
              (foreach line out (write-line line f))
              (write-line mark f)
              (write-line loadline f)
              (close f))))))
    nil))

;; NETLOAD the SchTagNet tag placer when its DLL is present.  Optional
;; on purpose: machines installed from the LISP-only zip or the pre-1.1
;; email installer have no DLL until their first DSLDUPDATE, and that
;; must never cost them the LISP tools.  The assembly can only load
;; once per session, so the blackboard flag (session-global, unlike
;; per-document lisp symbols) makes later drawings skip it.
(defun dsld:netload-schtagnet ( / dir dll)
  (if (null (vl-bb-ref 'dsld:netloaded))
    (progn
      (setq dir (dsld:dir))
      (if (and dir (setq dll (findfile (strcat dir "\\SchTagNet.dll"))))
        (progn
          (vl-catch-all-apply 'vl-cmdf (list "_.NETLOAD" dll))
          (vl-bb-set 'dsld:netloaded T)
          (princ "\n[DSLD] SchTagNet tag placer loaded (SCHTAG commands)."))))))

;; force nil: skip when this document already loaded the tools (the
;; acaddoc.lsp hook AND the bundle can both fire in one document -
;; parsing ~460 KB of LISP twice per drawing is pure waste).  force T
;; (DSLDRELOAD, post-update) always reloads.
(defun dsld:load-all (force / dir errs e)
  (setq dir (dsld:dir))
  (cond
    ((and *dsld:loaded-this-doc* (null force)) nil)
    ((null dir)
     (princ "\n[DSLD] DSLD-Tools.bundle not found under ApplicationPlugins - nothing loaded."))
    (t
     (setq *dsld:loaded-this-doc* T)
     (dsld:ensure-trusted dir)
     (dsld:ensure-support-path dir)
     (dsld:ensure-acaddoc-hook dir)
     (foreach name *dsld:files*
       (if (setq e (dsld:load1 dir name)) (setq errs (cons e errs))))
     ;; NETLOAD is a command, so it must wait for S::STARTUP - this
     ;; file runs while the document is still loading, where command
     ;; calls are unsafe.  Hook once per document.
     (if (null *dsld:startup-hooked*)
       (progn
         (setq *dsld:startup-hooked* T)
         (cond
           ((= (type S::STARTUP) 'LIST)
            (setq S::STARTUP
              (append S::STARTUP '((dsld:netload-schtagnet)))))
           (S::STARTUP
            (setq *dsld:old-startup* S::STARTUP)
            (defun-q S::STARTUP ( )
              (*dsld:old-startup*)
              (dsld:netload-schtagnet)))
           (t
            (defun-q S::STARTUP ( ) (dsld:netload-schtagnet))))))
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

;; HEAD url -> Content-Length as an integer, nil on any failure.
;; Cheap staleness probe for binary files (no LISP-side byte compare).
(defun dsld:remote-size (url / xml n)
  (vl-catch-all-apply
    (function
      (lambda ( / s)
        (setq xml (vlax-create-object "WinHttp.WinHttpRequest.5.1"))
        (vlax-invoke-method xml 'SetTimeouts 2000 2000 2000 8000)
        (vlax-invoke-method xml 'Open "HEAD" url :vlax-false)
        (vlax-invoke-method xml 'Send)
        (if (= 200 (vlax-get-property xml 'Status))
          (progn
            (setq s (vlax-invoke-method xml 'GetResponseHeader "Content-Length"))
            (if (and s (numberp (read s))) (setq n (read s)))))))
    nil)
  (if xml (vl-catch-all-apply 'vlax-release-object (list xml)))
  n)

;; GET url and save the raw bytes to path (ADODB.Stream, so the DLL
;; arrives byte-exact).  T on success.  Fails when AutoCAD has the DLL
;; loaded and locked - caller reports "restart and rerun".
(defun dsld:download-binary (url path / xml ok)
  (vl-catch-all-apply
    (function
      (lambda ( / stream)
        (setq xml (vlax-create-object "WinHttp.WinHttpRequest.5.1"))
        (vlax-invoke-method xml 'SetTimeouts 3000 3000 3000 30000)
        (vlax-invoke-method xml 'Open "GET" url :vlax-false)
        (vlax-invoke-method xml 'Send)
        (if (= 200 (vlax-get-property xml 'Status))
          (progn
            (setq stream (vlax-create-object "ADODB.Stream"))
            (vlax-put-property stream 'Type 1)      ; binary
            (vlax-invoke-method stream 'Open)
            (vlax-invoke-method stream 'Write
              (vlax-get-property xml 'ResponseBody))
            (vlax-invoke-method stream 'SaveToFile path 2) ; overwrite
            (vlax-invoke-method stream 'Close)
            (vlax-release-object stream)
            (setq ok T)))))
    nil)
  (if xml (vl-catch-all-apply 'vlax-release-object (list xml)))
  ok)

(defun c:DSLDUPDATE ( / dir p url body rsize n-new n-same n-fail n-bin)
  (setq n-new 0 n-same 0 n-fail 0 n-bin 0)
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
     ;; SchTagNet binaries: HEAD size-compare is the staleness probe
     ;; (a rebuilt DLL virtually never keeps the same byte count; when
     ;; in doubt DSLDUPDATE again after a restart forces nothing extra)
     (foreach name *dsld:binfiles*
       (setq p   (strcat dir "\\" name)
             url (strcat *dsld:raw-base* name))
       (princ (strcat "\n[DSLD] " name " ... "))
       (setq rsize (dsld:remote-size url))
       (cond
         ((null rsize)
          (princ "FETCH FAILED (no internet / GitHub unreachable?)")
          (setq n-fail (1+ n-fail)))
         ((and (findfile p) (= rsize (vl-file-size p)))
          (princ "already up to date")
          (setq n-same (1+ n-same)))
         ((dsld:download-binary url p)
          (princ "UPDATED")
          (setq n-bin (1+ n-bin)))
         (t
          (princ "write failed (AutoCAD is holding the add-in - restart CAD, then DSLDUPDATE again)")
          (setq n-fail (1+ n-fail)))))
     (if (> n-new 0) (dsld:load-all T))
     (princ (strcat "\n[DSLD] Update done: " (itoa (+ n-new n-bin)) " updated, "
                    (itoa n-same) " current, " (itoa n-fail) " failed."))
     (if (> n-new 0)
       (princ "\n[DSLD] New LISP code is live in THIS drawing; reopen other drawings to pick it up."))
     (if (> n-bin 0)
       (princ (strcat "\n[DSLD] SchTagNet add-in downloaded - it loads with the next drawing"
                      "\n       you open (restart first if an older copy was already in use).")))))
  (princ))

(defun c:DSLDRELOAD ( ) (dsld:load-all T))

;; run at load time - fired by the acaddoc.lsp hook in every drawing
;; (and by the AutoLoader / installer, whichever comes first)
(dsld:load-all nil)
