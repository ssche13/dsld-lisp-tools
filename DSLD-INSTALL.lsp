;;; ===================================================================
;;; DSLD-INSTALL.lsp - one-file installer for the DSLD CAD tools
;;;
;;; Email THIS file (it is small and plain text - no zip needed).
;;; The drafter saves it anywhere (Desktop is fine) and loads it once:
;;;   drag the file into an open drawing,  or  APPLOAD -> pick it.
;;;   (If AutoCAD asks about an untrusted location, click Load.)
;;;
;;; It then downloads the current DSLD-Tools.bundle from GitHub and
;;; writes it into the correct AutoCAD auto-load folder:
;;;   %APPDATA%\Autodesk\ApplicationPlugins\DSLD-Tools.bundle\
;;; The tools (RPR / SCH / ADIM) are live in the current drawing
;;; immediately, and load automatically in every drawing after the
;;; next AutoCAD restart.  Running it again reinstalls/updates - safe.
;;;
;;; Needs internet access.  Machines without it: install by copying
;;; the DSLD-Tools.bundle folder from a USB stick instead (README).
;;;
;;; Source: https://github.com/ssche13/dsld-lisp-tools
;;; ===================================================================
(vl-load-com)

(setq *dsldi:raw-base*
  "https://raw.githubusercontent.com/ssche13/dsld-lisp-tools/main/DSLD-Tools.bundle/")

;; GET url -> body string on HTTP 200, nil otherwise.  Tight timeouts
;; so a dead network cannot hang CAD.
(defun dsldi:http-get (url / xml body)
  (vl-catch-all-apply
    (function
      (lambda ( )
        (setq xml (vlax-create-object "WinHttp.WinHttpRequest.5.1"))
        (vlax-invoke-method xml 'SetTimeouts 3000 3000 3000 15000)
        (vlax-invoke-method xml 'Open "GET" url :vlax-false)
        (vlax-invoke-method xml 'Send)
        (if (= 200 (vlax-get-property xml 'Status))
          (setq body (vlax-get-property xml 'ResponseText)))))
    nil)
  (if xml (vl-catch-all-apply 'vlax-release-object (list xml)))
  body)

(defun dsldi:write (path s / f)
  (if (setq f (open path "w"))
    (progn (princ s f) (close f) T)))

(defun dsldi:install ( / appdata root bundle contents specs body fails)
  (setq appdata (getenv "APPDATA"))
  (cond
    ((null appdata)
     (princ "\n[DSLD-INSTALL] %APPDATA% not found - cannot install."))
    (t
     (setq root     (strcat appdata "\\Autodesk\\ApplicationPlugins")
           bundle   (strcat root "\\DSLD-Tools.bundle")
           contents (strcat bundle "\\Contents"))
     ;; vl-mkdir creates one level at a time and is a no-op when the
     ;; folder already exists
     (vl-mkdir (strcat appdata "\\Autodesk"))
     (vl-mkdir root)
     (vl-mkdir bundle)
     (vl-mkdir contents)
     ;; (repo-path  target-path  sanity-token  min-length) - never
     ;; write an error page or truncated download over a working tool
     (setq specs
       (list
         (list "PackageContents.xml"
               (strcat bundle "\\PackageContents.xml")
               "ApplicationPackage" 500)
         (list "Contents/DSLD-Loader.lsp"
               (strcat contents "\\DSLD-Loader.lsp")
               "(defun" 2000)
         (list "Contents/roof-pitch-rafters.lsp"
               (strcat contents "\\roof-pitch-rafters.lsp")
               "(defun" 10000)
         (list "Contents/SCH.lsp"
               (strcat contents "\\SCH.lsp")
               "(defun" 10000)
         (list "Contents/ADIM.lsp"
               (strcat contents "\\ADIM.lsp")
               "(defun" 5000)))
     (setq fails 0)
     (foreach spec specs
       (princ (strcat "\n[DSLD-INSTALL] downloading " (car spec) " ... "))
       (setq body (dsldi:http-get (strcat *dsldi:raw-base* (car spec))))
       (cond
         ((or (null body)
              (< (strlen body) (cadddr spec))
              (null (vl-string-search (caddr spec) body)))
          (princ "FAILED")
          (setq fails (1+ fails)))
         ((dsldi:write (cadr spec) body)
          (princ "ok"))
         (t
          (princ "WRITE FAILED (file in use?)")
          (setq fails (1+ fails)))))
     (cond
       ((> fails 0)
        (princ (strcat "\n[DSLD-INSTALL] " (itoa fails)
                       " file(s) failed - check internet access, then type DSLDINSTALL to retry.")))
       (t
        (load (strcat contents "\\DSLD-Loader.lsp"))
        (princ "\n[DSLD-INSTALL] Done.  RPR / SCH / ADIM are live in THIS drawing now.")
        (princ "\n[DSLD-INSTALL] Restart AutoCAD once and they will load in EVERY drawing automatically.")
        (princ "\n[DSLD-INSTALL] You can delete the DSLD-INSTALL.lsp file - it is no longer needed.")))))
  (princ))

;; retry command (available after the first load attempt)
(defun c:DSLDINSTALL ( ) (dsldi:install))

;; run immediately when the file is loaded
(dsldi:install)
