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

;; GET url and save the raw bytes to path (ADODB.Stream) - used for
;; the SchTagNet .NET add-in, which must arrive byte-exact.
(defun dsldi:download-binary (url path / xml ok)
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
     ;; register the bundle with SECURELOAD *before* anything loads
     ;; from it, so the only security prompt the user ever sees is the
     ;; one for this installer file itself.  Root before Contents (the
     ;; root path is a substring of the Contents path, keeping the
     ;; already-present check honest).  Fail-soft.
     (vl-catch-all-apply
       (function
         (lambda ( / tp)
           (foreach d (list bundle contents)
             (setq tp (getvar "TRUSTEDPATHS"))
             (if (null tp) (setq tp ""))
             (if (null (vl-string-search (strcase d) (strcase tp)))
               (setvar "TRUSTEDPATHS"
                       (if (= tp "") d (strcat tp ";" d)))))))
       nil)
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
     ;; binary payloads: the SchTagNet schedule-tag add-in
     (foreach spec
       (list
         (list "Contents/SchTagNet.dll"
               (strcat contents "\\SchTagNet.dll") 10000)
         (list "Contents/SchTagNet.deps.json"
               (strcat contents "\\SchTagNet.deps.json") 100)
         (list "Contents/SchTagNet.runtimeconfig.json"
               (strcat contents "\\SchTagNet.runtimeconfig.json") 100))
       (princ (strcat "\n[DSLD-INSTALL] downloading " (car spec) " ... "))
       (cond
         ((and (dsldi:download-binary (strcat *dsldi:raw-base* (car spec))
                                      (cadr spec))
               (vl-file-size (cadr spec))
               (> (vl-file-size (cadr spec)) (caddr spec)))
          (princ "ok"))
         (t
          (princ "FAILED")
          (setq fails (1+ fails)))))
     (cond
       ((> fails 0)
        (princ (strcat "\n[DSLD-INSTALL] " (itoa fails)
                       " file(s) failed - check internet access, then type DSLDINSTALL to retry.")))
       (t
        (load (strcat contents "\\DSLD-Loader.lsp"))
        (princ "\n[DSLD-INSTALL] Done.  RPR / SCH / ADIM are live in THIS drawing now.")
        (princ "\n[DSLD-INSTALL] Restart AutoCAD once and they will load in EVERY drawing")
        (princ "\n               automatically (the SCHTAG tag placer needs that restart too).")
        (princ "\n[DSLD-INSTALL] You can delete the DSLD-INSTALL.lsp file - it is no longer needed.")))))
  (princ))

;; retry command (available after the first load attempt)
(defun c:DSLDINSTALL ( ) (dsldi:install))

;; run immediately when the file is loaded
(dsldi:install)
