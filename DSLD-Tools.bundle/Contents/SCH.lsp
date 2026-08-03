;;; ===================================================================
;;; SCH.lsp - DSLD Schedule of Openings auto-fill
;;; Target platform: AutoCAD Architecture (ACA)
;;;
;;; Commands:
;;;   SCH      - harvest door/window/opening data from a selected plan
;;;              region, preview the proposed WINDOW SCHEDULE and DOOR
;;;              SCHEDULE contents in a dialog, then write the accepted
;;;              values into the two ACAD_TABLE schedule tables.
;;;   SCHDIAG  - diagnostic: census of AEC objects / tags / tables in
;;;              the drawing, plus deep-dump of picked entities
;;;              (properties, property sets, explode test). Writes
;;;              SCHDIAG-report.txt next to the drawing. Run this in
;;;              ACA on a real plan and send the report back so the
;;;              data-extraction layer can be hardened.
;;;
;;; Data sources (tried in order, per object):
;;;   1. ACA property sets via AecX.AecScheduleApplication
;;;      (DoorObjects / WindowObjects: DSLD_NUMBER,
;;;       StandardSizeDescription, plus any Swing/Hand property)
;;;   2. Direct ActiveX properties on AecDbDoor/AecDbWindow
;;;      (Width, Height, style name)
;;;   3. Fallback for flattened DWGs/DXFs (and BricsCAD testing):
;;;      plain INSERTs of TK_Door_Tag*_P / TK_Window_Tag*_P attributed
;;;      blocks (mark bubbles paired with size tags by proximity).
;;;
;;; LH/RH swing: derived geometrically - the door is copied, the copy
;;; exploded to primitives, the swing ARC + leaf line analyzed against
;;; the host wall direction, then all temp entities deleted.
;;; Convention (configurable below): viewer stands on the side the door
;;; opens AWAY from; hinge on viewer's left = LH.
;;;
;;; Cased openings: AecDbOpening objects, or doors whose style name
;;; contains "ARCH" (TK_Arch family). Host wall Width < threshold
;;; classifies as 4" wall, otherwise 6" wall; result is written into
;;; the DESCRIPTION as e.g.  CASED OPENING - 6" WALL
;;; ===================================================================

(vl-load-com)

;;; ------------------------------------------------------------------
;;; Configuration
;;; ------------------------------------------------------------------

(setq *sch:version* "2.10")
(setq *sch:layer* "SCH")          ; layer for charts SCH creates
(setq *sch:home* "E:/Megans lisp routines/SCH.lsp") ; default install path
(setq *sch:raw-base*
  "https://raw.githubusercontent.com/ssche13/dsld-lisp-tools/main/DSLD-Tools.bundle/Contents/")

(setq *sch:wall6-threshold* 5.0)  ; host wall Width >= 5.0" => 6" wall
(setq *sch:hand-convention* "AWAY") ; "AWAY": viewer on the side the door
                                    ; opens away from (US standard).
                                    ; "TOWARD" flips LH/RH.
(setq *sch:tagpair-dist* 40.0)    ; max distance (in) between a mark
                                  ; bubble and its size tag (INSERT
                                  ; fallback provider), scaled by the
                                  ; bubble's insert scale.
(setq *sch:use-aecx* T)           ; nil = never touch the AecX COM
                                  ; interface (set nil if it crashes)
(setq *sch:use-explode* nil)      ; DEFAULT OFF as of v2.9. Copying and
                                  ; exploding a live AecDbDoor runs the
                                  ; ACA enabler's own explode code and
                                  ; can hard-crash AutoCAD (a process
                                  ; fault vl-catch-all-apply CANNOT
                                  ; catch). sch:door-hand falls back to
                                  ; the probe method, which is what
                                  ; BricsCAD already uses - so LH/RH
                                  ; still works. Set T to re-enable the
                                  ; arc-based swing detection.
(setq *sch:trace* T)              ; T = breadcrumb every risky COM call
                                  ; to SCH-trace.txt beside the DWG,
                                  ; flushed per line, so if CAD dies the
                                  ; LAST line names the object and the
                                  ; operation that killed it. SCHTRACE
                                  ; toggles; costs one file open per
                                  ; risky call.
(setq *sch:trace-path* nil)       ; resolved at command start
(setq *sch:tagnear* 60.0)         ; an opening is "already tagged" when
                                  ; a tag entity sits within this many
                                  ; inches of its center (SCHTAGS)
(setq *sch:tag-path* nil)         ; SCHTAGS report path
(setq *sch:chk-path* nil)         ; SCHCHECK report path
(setq *sch:diag-path* nil)        ; report path, set by SCHDIAG
(setq *sch:qtymode* "replace")    ; "replace" = matched rows get this
                                  ; scan's counts; "add" = counts are
                                  ; ADDED (scanning another area)
(setq *sch:addmode* nil)          ; internal merge switch
(setq *sch:explode-broken* nil)   ; set T automatically after repeated
(setq *sch:explode-fails* 0)      ; explode failures (session cache)

;; Standard DSLD descriptions written into NEW schedule rows (existing
;; text is never overwritten). First style-name pattern that matches
;; wins - edit these freely to match office wording.
(setq *sch:desc-map*
  '(("*GARAGE*"   . "OVERHEAD GARAGE DOOR")
    ("*POCKET*"   . "POCKET - INT. GRADE - SEE P.O.")
    ("*BIFOLD*"   . "BIFOLD - INT. GRADE - SEE P.O.")
    ("*DOORWALL*" . "SLIDING GLASS DOOR")
    ("*EXTERIOR*" . "EXT. GRADE - FIBERGLASS")))
(setq *sch:desc-door-default* "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
(setq *sch:desc-window-default* "1/1 EQ. SASH - VINYL SINGLE HUNG")

;; Casing math, measured from the DSLD style libraries: casing is a
;; 3.5" 1x4 (2.5" beyond the 1.5" jamb/frame). A door drawn to the
;; outside of its casing = leaf + 8"; a window = width + 5". Cased
;; openings (Doorway_Arch) draw at face value - no correction.
;; If snapped sizes come out one size SMALL, the door style measures
;; to the wall opening instead - change 8.0 to 3.0.
(setq *sch:door-trim-allow* 8.0)
(setq *sch:win-trim-allow* 7.0)  ; empirical: real Timsbury windows
                                 ; measure nominal + 7" over casing
(setq *sch:snap-tol* 6.0) ; max inches between measured and standard
                          ; (16' garage doors measure ~+5 over allowance)

;; DSLD standard catalog - mined from 61 real schedule tables across
;; 7 plan families (569 doors / 297 windows, QTY-weighted), ordered
;; most-common first. (width height "most common description")
(setq *sch:std-doors*
  '((32.0 80.0 "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
    (28.0 80.0 "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
    (48.0 80.0 "DBL. 4068 INT. GRADE - HOLLOW CORE - SEE P.O.")
    (24.0 80.0 "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
    (36.0 80.0 "4 LITE EXT. GRADE W/ BOTTOM PANEL")
    (192.0 84.0 "OVERHEAD GARAGE DOOR")
    (18.0 80.0 "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
    (42.0 96.0 "CASED OPENING")
    (48.0 96.0 "CASED OPENING")
    (36.0 96.0 "EXTERIOR GRADE - SEE P.O.")
    (96.0 96.0 "CASED OPENING")))
(setq *sch:std-windows*
  '((36.0 72.0 "1/1 EQ. SASH - VINYL SINGLE HUNG")
    (36.0 36.0 "FIXED - OBSCURE - TEMPERED")
    (36.0 66.0 "4/4 EQ. SASH - VINYL SINGLE HUNG")
    (38.0 38.0 "FIXED - RAIN PATTERN - TEMPERED")
    (72.0 72.0 "DBL. 3060 - 4/4 EQ. SASH - VINYL SINGLE HUNG")
    (24.0 48.0 "6 LITE FIXED")))

;;; ------------------------------------------------------------------
;;; Generic guarded-call utilities
;;; ------------------------------------------------------------------

(defun sch:catch (f args / r)
  (setq r (vl-catch-all-apply f args))
  (if (vl-catch-all-error-p r) nil r))

;;; ---- crash breadcrumbs -------------------------------------------
;;; A hard CAD crash (process fault) cannot be caught by
;;; vl-catch-all-apply and leaves no LISP error. So before every risky
;;; COM/explode call we append one line to SCH-trace.txt and CLOSE the
;;; file, forcing a flush. If CAD dies, the last line in that file
;;; names the exact object and operation that killed it.

(defun sch:trace-init ( / p fh)
  (setq p (strcat (getvar "DWGPREFIX") "SCH-trace.txt"))
  (setq fh (open p "w"))
  (if (null fh)                       ; read-only folder / network dwg
    (progn
      (setq p (strcat (getvar "TEMPPREFIX") "SCH-trace.txt"))
      (setq fh (open p "w"))))
  (if fh
    (progn
      (write-line (strcat "SCH v" *sch:version* " trace  dwg: "
                          (getvar "DWGNAME"))
                  fh)
      (close fh)
      (setq *sch:trace-path* p))
    (setq *sch:trace-path* nil))
  *sch:trace-path*)

(defun sch:tr (msg / fh)
  (if (and *sch:trace* *sch:trace-path*)
    (progn
      (setq fh (open *sch:trace-path* "a"))
      (if fh (progn (write-line msg fh) (close fh)))))
  (princ))

;; short identity for a vla-object, safe on AEC proxies
(defun sch:tr-id (obj / h n)
  (setq h (sch:prop obj 'Handle)
        n (sch:catch 'vla-get-ObjectName (list obj)))
  (strcat (if (eq (type n) 'STR) n "?")
          " handle=" (if (eq (type h) 'STR) h "?")))

(defun c:SCHTRACE ()
  (princ (strcat "\n[SCH v" *sch:version* "]"))
  (setq *sch:trace* (not *sch:trace*))
  (princ (strcat "\n[SCH] Crash trace "
                 (if *sch:trace* "ON" "OFF")
                 " (SCH-trace.txt beside the drawing)."))
  (princ))

(defun sch:prop (obj name)
  (if (and obj (eq (type obj) 'VLA-OBJECT)
           (vlax-property-available-p obj name))
    (sch:catch 'vlax-get-property (list obj name))))

(defun sch:invoke (obj meth args)
  (if (and obj (eq (type obj) 'VLA-OBJECT))
    (sch:catch 'vlax-invoke (append (list obj meth) args))))

(defun sch:vla (e)
  (cond ((eq (type e) 'ENAME) (sch:catch 'vlax-ename->vla-object (list e)))
        ((eq (type e) 'VLA-OBJECT) e)))

(defun sch:objname (o / v)
  (setq v (sch:vla o))
  (if v (sch:prop v 'ObjectName) ""))

(defun sch:val->str (v)
  (cond ((null v) "")
        ((eq (type v) 'STR) v)
        ((eq (type v) 'INT) (itoa v))
        ((eq (type v) 'REAL) (rtos v 2 4))
        ((eq (type v) 'VARIANT)
         (sch:val->str (sch:catch 'vlax-variant-value (list v))))
        (t "")))

;;; ------------------------------------------------------------------
;;; String / formatting utilities
;;; ------------------------------------------------------------------

(defun sch:trim (s)
  (if s (vl-string-trim " \t" s) ""))

;; Strip common MTEXT formatting codes; \Sa#b; becomes a/b.
;; Handles semicolon-less codes (\P \~ \\ \{ \} \L \l \O \o \K \k)
;; separately from ;-terminated ones (\A1; \H0.7x; \S4#4; \C \f \p ...).
(defun sch:strip-fmt (s / i n c out code nxt)
  (if (null s) (setq s ""))
  (setq i 1 n (strlen s) out "")
  (while (<= i n)
    (setq c (substr s i 1))
    (cond
      ((or (= c "{") (= c "}")) (setq i (1+ i)))
      ((= c "\\")
       (setq nxt (if (< i n) (substr s (1+ i) 1) ""))
       (cond
         ((member nxt '("\\" "{" "}")) ; escaped literals
          (setq out (strcat out nxt) i (+ i 2)))
         ((member nxt '("P" "~")) ; hard line break / nbsp -> space
          (setq out (strcat out " ") i (+ i 2)))
         ((member nxt '("L" "l" "O" "o" "K" "k")) ; format toggles
          (setq i (+ i 2)))
         (t ; ;-terminated codes
          (setq code "" i (1+ i))
          (while (and (<= i n) (/= (substr s i 1) ";")
                      (< (strlen code) 40))
            (setq code (strcat code (substr s i 1)) i (1+ i)))
          (if (and (<= i n) (= (substr s i 1) ";"))
            (setq i (1+ i))) ; skip ";" only if actually there
          (if (and (> (strlen code) 1)
                   (= (strcase (substr code 1 1)) "S"))
            ;; stacked fraction \S4#4; -> 4/4
            (setq out (strcat out
                              (vl-string-translate "#" "/"
                                                   (substr code 2))))))))
      (t (setq out (strcat out c)) (setq i (1+ i)))))
  (sch:trim out))

;; inches -> 2'-8"  (whole inches expected; shows one decimal otherwise)
(defun sch:ftin (in / ft rem)
  (setq ft (fix (/ in 12.0))
        rem (- in (* ft 12)))
  (if (equal rem (float (fix (+ rem 0.5e-3))) 1e-2)
    (setq rem (float (fix (+ rem 0.5e-3)))))
  (if (>= rem 11.95) ; carry rounded-up inches into feet: 2'-12" -> 3'-0"
    (setq ft (1+ ft) rem 0.0))
  (strcat (itoa ft) "'-"
          (if (equal rem (float (fix rem)) 1e-6)
            (itoa (fix rem))
            (rtos rem 2 1))
          "\""))

(defun sch:alldigits-p (s / i ok)
  (setq ok (> (strlen s) 0) i 1)
  (while (and ok (<= i (strlen s)))
    (if (not (<= 48 (ascii (substr s i 1)) 57)) (setq ok nil))
    (setq i (1+ i)))
  ok)

;; Parse a DSLD size code -> (mult widthIn heightIn) or nil.
;; "2668" -> (1 30.0 80.0)   "8080" -> (1 96.0 96.0)
;; "16070" -> (1 192.0 84.0) "2-2668"/"DBL. 2668" -> (2 30.0 80.0)
;; "8X7"/"16X7" garage and "3X4"/"4X5" window shorthand (feet x feet)
(defun sch:parse-size (raw / s mult d1 d2 d3 d4 d5 n p)
  (setq s (strcase (sch:trim raw)) mult 1)
  (cond ((wcmatch s "DBL*")
         (setq mult 2 s (sch:trim (vl-string-trim ". " (substr s 4))))))
  (if (wcmatch s "#-####") ; e.g. 2-2668
    (progn (setq mult (atoi (substr s 1 1)))
           (setq s (substr s 3))))
  (setq n (strlen s))
  (cond
    ((wcmatch s "#X#,##X#,#X##,##X##") ; feet x feet: 8X7, 16X7, 3X4
     (setq p (vl-string-search "X" s))
     (list mult (* 12.0 (atoi (substr s 1 p)))
           (* 12.0 (atoi (substr s (+ p 2))))))
    ((not (sch:alldigits-p s)) nil)
    ((= n 4)
     (setq d1 (atoi (substr s 1 1)) d2 (atoi (substr s 2 1))
           d3 (atoi (substr s 3 1)) d4 (atoi (substr s 4 1)))
     (list mult (+ (* d1 12.0) d2) (+ (* d3 12.0) d4)))
    ((= n 5) ; 2-digit feet width, e.g. 16070 = 16'-0" x 7'-0"
     (setq d1 (atoi (substr s 1 2)) d2 (atoi (substr s 3 1))
           d3 (atoi (substr s 4 1)) d4 (atoi (substr s 5 1)))
     (list mult (+ (* d1 12.0) d2) (+ (* d3 12.0) d4)))
    (t nil)))

;;; ------------------------------------------------------------------
;;; Geometry utilities
;;; ------------------------------------------------------------------

(defun sch:bbox (vlaObj / mn mx)
  ;; GetBoundingBox is a void method - success is signaled by the
  ;; out-params mn/mx being filled, never by the return value.
  (sch:catch 'vla-GetBoundingBox (list vlaObj 'mn 'mx))
  (if (and mn mx)
    (list (vlax-safearray->list mn) (vlax-safearray->list mx))))

(defun sch:bbox-center (vlaObj / bb)
  (if (setq bb (sch:bbox vlaObj))
    (mapcar '(lambda (a b) (/ (+ a b) 2.0)) (car bb) (cadr bb))))

(defun sch:pt2 (p) (list (car p) (cadr p)))

(defun sch:v- (a b) (mapcar '- (sch:pt2 a) (sch:pt2 b)))
(defun sch:v+ (a b) (mapcar '+ (sch:pt2 a) (sch:pt2 b)))
(defun sch:vscale (v s) (mapcar '(lambda (x) (* x s)) v))
(defun sch:vdot (a b) (apply '+ (mapcar '* a b)))
(defun sch:vlen (v) (sqrt (sch:vdot v v)))
(defun sch:vunit (v / l) (setq l (sch:vlen v))
  (if (> l 1e-9) (sch:vscale v (/ 1.0 l)) '(0.0 0.0)))
(defun sch:vperp (v) (list (- (cadr v)) (car v)))
(defun sch:vcross (a b) (- (* (car a) (cadr b)) (* (cadr a) (car b))))

;; distance from point p to segment a-b (2D)
(defun sch:dist-pt-seg (p a b / ab ap tparam proj)
  (setq ab (sch:v- b a) ap (sch:v- p a))
  (if (< (sch:vlen ab) 1e-9)
    (sch:vlen ap)
    (progn
      (setq tparam (/ (sch:vdot ap ab) (sch:vdot ab ab)))
      (if (< tparam 0.0) (setq tparam 0.0))
      (if (> tparam 1.0) (setq tparam 1.0))
      (setq proj (sch:v+ a (sch:vscale ab tparam)))
      (sch:vlen (sch:v- p proj)))))

;; transform a local point by an insert's placement (2D; handles
;; mirror via negative scales; ignores OCS - plans are WCS)
(defun sch:xform-pt (pt ip rot sx sy / x y c s)
  (setq x (* (car pt) sx) y (* (cadr pt) sy)
        c (cos rot) s (sin rot))
  (list (+ (car ip) (- (* x c) (* y s)))
        (+ (cadr ip) (+ (* x s) (* y c)))))

(defun sch:pt-in-box (p p1 p2)
  (and (>= (car p) (min (car p1) (car p2)))
       (<= (car p) (max (car p1) (car p2)))
       (>= (cadr p) (min (cadr p1) (cadr p2)))
       (<= (cadr p) (max (cadr p1) (cadr p2)))))

;;; ------------------------------------------------------------------
;;; AecX bridge - property sets
;;; ------------------------------------------------------------------

(defun sch:sched-app ( / vlist app)
  (cond
    ((not *sch:use-aecx*) nil)
    (*sch:schedapp* *sch:schedapp*)
    ((eq *sch:schedapp-failed* T) nil)
    (t
     (setq vlist '("" ".9.7" ".9.5" ".9.0" ".8.9" ".8.8" ".8.7" ".8.5"
                   ".8.0" ".7.9" ".7.7" ".7.5" ".7.0" ".6.7" ".6.5"
                   ".6.0" ".5.5" ".5.0" ".4.7" ".4.5"))
     (foreach v vlist
       (if (and (null *sch:schedapp*)
                (setq app (sch:catch 'vla-GetInterfaceObject
                            (list (vlax-get-acad-object)
                                  (strcat "AecX.AecScheduleApplication" v)))))
         (progn (setq *sch:schedapp* app *sch:schedapp-ver* v))))
     (if (null *sch:schedapp*) (setq *sch:schedapp-failed* T))
     *sch:schedapp*)))

;; Return property sets of an object as
;; (("DOOROBJECTS" ("DSLD_NUMBER" . "5") ("STANDARDSIZEDESCRIPTION" . "2668") ...) ...)
(defun sch:psets (vlaObj / app sets out props pl nm)
  (setq app (sch:sched-app))
  (if app
    (progn
      (sch:tr (strcat "  AecX PropertySets -> " (sch:tr-id vlaObj)))
      (setq sets (sch:invoke app 'PropertySets (list vlaObj)))
      (if (null sets)
        (setq sets (sch:catch 'vlax-get-property
                     (list app 'PropertySets vlaObj))))
      (if (and sets (eq (type sets) 'VLA-OBJECT))
        (sch:catch
          '(lambda ()
             (vlax-for ps sets
               (setq pl nil
                     nm (strcase (sch:val->str (sch:prop ps 'Name))))
               (setq props (sch:prop ps 'Properties))
               (if props
                 (sch:catch
                   '(lambda ()
                      (vlax-for p props
                        (setq pl (cons (cons (strcase (sch:val->str
                                                        (sch:prop p 'Name)))
                                             (sch:val->str (sch:prop p 'Value)))
                                       pl))))
                   nil))
               (setq out (cons (cons nm (reverse pl)) out))))
          nil))))
  out)

;; find a property value by property-set-name pattern + property-name pattern
(defun sch:pset-val (psets setpat proppat / out)
  (foreach ps psets
    (if (and (null out) (wcmatch (car ps) setpat))
      (foreach pr (cdr ps)
        (if (and (null out) (wcmatch (car pr) proppat))
          (setq out (cdr pr))))))
  out)

;;; ------------------------------------------------------------------
;;; Walls - census and nearest-wall width
;;; ------------------------------------------------------------------

;; each wall record: (p1 p2 widthOrNil)
(defun sch:wall-record (vlaW / sp ep bb p1 p2 w mn mx dx dy)
  (setq w (sch:prop vlaW 'Width))
  (if (eq (type w) 'VARIANT) (setq w (sch:catch 'vlax-variant-value (list w))))
  (if (not (numberp w)) (setq w nil))
  (setq sp (sch:prop vlaW 'StartPoint)
        ep (sch:prop vlaW 'EndPoint))
  (if (eq (type sp) 'VARIANT)
    (setq sp (sch:catch 'vlax-safearray->list
               (list (vlax-variant-value sp)))))
  (if (eq (type ep) 'VARIANT)
    (setq ep (sch:catch 'vlax-safearray->list
               (list (vlax-variant-value ep)))))
  (cond
    ((and sp ep (listp sp) (listp ep))
     (list (sch:pt2 sp) (sch:pt2 ep) w))
    ((setq bb (sch:bbox vlaW))
     (setq mn (car bb) mx (cadr bb)
           dx (- (car mx) (car mn)) dy (- (cadr mx) (cadr mn)))
     ;; baseline = midline along the long axis; short axis approximates width
     (if (>= dx dy)
       (list (list (car mn) (/ (+ (cadr mn) (cadr mx)) 2.0))
             (list (car mx) (/ (+ (cadr mn) (cadr mx)) 2.0))
             (if w w (if (< dy 24.0) dy nil)))
       (list (list (/ (+ (car mn) (car mx)) 2.0) (cadr mn))
             (list (/ (+ (car mn) (car mx)) 2.0) (cadr mx))
             (if w w (if (< dx 24.0) dx nil)))))))

(defun sch:collect-walls ( / ss i rec out)
  (setq out nil)
  (setq ss (ssget "_X" '((0 . "AEC_WALL") (410 . "Model"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq rec (sch:wall-record (sch:vla (ssname ss i))))
        (if rec (setq out (cons rec out)))
        (setq i (1+ i)))))
  out)

;; nearest wall to pt within maxd -> wall record or nil
(defun sch:nearest-wall (pt walls maxd / best bestd d)
  (setq bestd maxd)
  (foreach w walls
    (setq d (sch:dist-pt-seg pt (car w) (cadr w)))
    (if (< d bestd) (setq bestd d best w)))
  best)

(defun sch:wall-class (wrec / w)
  (if (and wrec (setq w (caddr wrec)))
    (if (>= w *sch:wall6-threshold*) "6" "4")))

;;; ------------------------------------------------------------------
;;; Swing-hand detection (explode a copy, analyze arc + leaf)
;;; ------------------------------------------------------------------

;; explode a copy of vlaObj (2 levels), return list of vla primitives.
;; caller must delete them with sch:del-ents.
;; ActiveX ONLY - never the command line: feeding _EXPLODE into the
;; command stream mid-session collided with pending commands (BricsCAD
;; BIM section prompts) and is banned. After 3 consecutive failures,
;; swing detection is switched off for the rest of the session.
(defun sch:explode-copy (vlaObj / cp res out sub subres)
  (if (null *sch:explode-fails*) (setq *sch:explode-fails* 0))
  (if (not *sch:explode-broken*)
    (progn
      (sch:tr (strcat "  EXPLODE copy -> " (sch:tr-id vlaObj)
                      "   <-- if this is the last line, the ACA explode"
                      " killed CAD: leave *sch:use-explode* nil"))
      (setq cp (sch:catch 'vla-Copy (list vlaObj)))
      (setq res (if cp (sch:invoke cp 'Explode nil)))
      (if cp (sch:catch 'vla-Delete (list cp)))
      (sch:tr "  EXPLODE ok")
      (if res
        (progn
          (setq *sch:explode-fails* 0)
          ;; explode nested inserts one more level
          (setq sub nil)
          (foreach o res
            (if (and o (= (sch:objname o) "AcDbBlockReference"))
              (progn
                (setq subres (sch:invoke o 'Explode nil))
                (if subres
                  (progn (setq sub (append sub subres))
                         (sch:catch 'vla-Delete (list o)))
                  (setq sub (cons o sub))))
              (if o (setq sub (cons o sub)))))
          (setq out (vl-remove nil sub)))
        (progn
          (setq *sch:explode-fails* (1+ *sch:explode-fails*))
          (if (>= *sch:explode-fails* 3)
            (progn
              (setq *sch:explode-broken* T)
              (princ "\n[SCH] These objects cannot be exploded - swing detection off for this session.")))))))
  out)

(defun sch:del-ents (lst)
  (foreach o lst (if o (sch:catch 'vla-Delete (list o)))))

(defun sch:arc-data (vlaArc / c r a1 a2)
  (setq c (sch:prop vlaArc 'Center))
  (if (eq (type c) 'VARIANT)
    (setq c (sch:catch 'vlax-safearray->list (list (vlax-variant-value c)))))
  (setq r (sch:prop vlaArc 'Radius)
        a1 (sch:prop vlaArc 'StartAngle)
        a2 (sch:prop vlaArc 'EndAngle))
  (if (and c r a1 a2) (list (sch:pt2 c) r a1 a2)))

(defun sch:line-ends (vlaLine / a b)
  (setq a (sch:prop vlaLine 'StartPoint) b (sch:prop vlaLine 'EndPoint))
  (if (eq (type a) 'VARIANT)
    (setq a (sch:catch 'vlax-safearray->list (list (vlax-variant-value a)))))
  (if (eq (type b) 'VARIANT)
    (setq b (sch:catch 'vlax-safearray->list (list (vlax-variant-value b)))))
  (if (and a b) (list (sch:pt2 a) (sch:pt2 b))))

;; core hand computation.
;; c=hinge, r=radius, a1/a2=arc angles, wallP1/wallP2 = wall baseline
;; (or leaf-derived pseudo-baseline). Returns "LH" / "RH" / nil.
(defun sch:hand-calc (c r a1 a2 wallP1 wallP2 / delta mid midpt e1 e2
                      strike wdir wnorm side swingn viewdir leftdir dvec)
  (setq delta (- a2 a1))
  (if (< delta 0.0) (setq delta (+ delta (* 2.0 pi))))
  (setq mid (+ a1 (/ delta 2.0))
        midpt (sch:v+ c (list (* r (cos mid)) (* r (sin mid))))
        e1 (sch:v+ c (list (* r (cos a1)) (* r (sin a1))))
        e2 (sch:v+ c (list (* r (cos a2)) (* r (sin a2))))
        wdir (sch:vunit (sch:v- wallP2 wallP1))
        wnorm (sch:vperp wdir))
  (if (< (sch:vlen wdir) 1e-9)
    nil
    (progn
      ;; strike endpoint = arc endpoint closest to the wall line
      (setq strike
        (if (< (sch:dist-pt-seg e1 wallP1 wallP2)
               (sch:dist-pt-seg e2 wallP1 wallP2))
          e1 e2))
      ;; which side of the wall the arc bulges to
      (setq side (sch:vdot (sch:v- midpt c) wnorm))
      (if (equal side 0.0 1e-9)
        nil
        (progn
          (setq swingn (sch:vscale wnorm (if (> side 0.0) 1.0 -1.0)))
          ;; viewer stands opposite the swing, looking through the door
          (setq viewdir swingn)
          (if (= (strcase *sch:hand-convention*) "TOWARD")
            (setq viewdir (sch:vscale viewdir -1.0)))
          (setq leftdir (sch:vperp viewdir)) ; viewer's left
          (setq dvec (sch:v- strike c))     ; hinge -> strike
          ;; hinge relative to door center = -dvec/2
          (if (> (sch:vdot (sch:vscale dvec -0.5) leftdir) 0.0)
            "LH" "RH"))))))

;; ------------------------------------------------------------------
;; Probe-based swing detection (no explode, no command line): cast a
;; temporary line across the swing region and intersect it with the
;; door entity itself. A 90-degree-open door's leaf lies at the hinge
;; end of its bbox; the arc crossing lies mid-span. Works on AEC
;; doors in BricsCAD where explode and properties are sealed.
;; ------------------------------------------------------------------

;; pure decision: a0/a1 = door extent along the wall, hingeA = hinge
;; position along the wall, swingn = unit normal toward the swing
;; side, wdir = wall direction. Convention as sch:hand-calc.
(defun sch:probe-decide (a0 a1 hingeA swingn wdir / viewdir leftdir
                          centerA dotv)
  (setq viewdir swingn)
  (if (= (strcase *sch:hand-convention*) "TOWARD")
    (setq viewdir (sch:vscale viewdir -1.0)))
  (setq leftdir (sch:vperp viewdir)
        centerA (/ (+ a0 a1) 2.0)
        dotv (sch:vdot (sch:vscale wdir (- hingeA centerA)) leftdir))
  (if (> dotv 0.0) "LH" "RH"))

;; group sorted 1D values into (center count) clusters by gap
(defun sch:cluster-1d (vals tol / out cursum curn last x)
  (if vals
    (progn
      (setq vals (vl-sort vals '<)
            cursum (car vals) curn 1 last (car vals))
      (foreach x (cdr vals)
        (if (< (- x last) tol)
          (setq cursum (+ cursum x) curn (1+ curn))
          (progn
            (setq out (cons (list (/ cursum curn) curn) out))
            (setq cursum x curn 1)))
        (setq last x))
      (setq out (cons (list (/ cursum curn) curn) out))
      (reverse out))))

(defun sch:door-hand-probe (vlaDoor walls / bb mn mx c wrec wp1 wp2
                             wdir wnorm alongv perpv a0 a1 dpth swingn
                             d margin p1 p2 probe raw alongs minI maxI
                             hingeA hand n doc msp pt clusters leafC
                             arcC)
  ;; diagnostics trail for SCHDIAG/SCHTEST
  (setq *sch:probe-last* '(("stage" . "no-bbox")))
  (setq bb (sch:bbox vlaDoor))
  (setq c (if bb (mapcar '(lambda (a b) (/ (+ a b) 2.0))
                         (car bb) (cadr bb))))
  (setq wrec (if c (sch:nearest-wall c walls 30.0)))
  (if wrec
    (progn
      (setq mn (car bb) mx (cadr bb)
            wp1 (car wrec) wp2 (cadr wrec)
            wdir (sch:vunit (sch:v- wp2 wp1))
            wnorm (sch:vperp wdir)
            dpth 0.0)
      (foreach pt (list (sch:pt2 mn)
                        (list (car mn) (cadr mx))
                        (list (car mx) (cadr mn))
                        (sch:pt2 mx))
        (setq alongv (sch:vdot (sch:v- pt wp1) wdir)
              perpv (sch:vdot (sch:v- pt wp1) wnorm))
        (if (or (null a0) (< alongv a0)) (setq a0 alongv))
        (if (or (null a1) (> alongv a1)) (setq a1 alongv))
        (if (> (abs perpv) (abs dpth)) (setq dpth perpv)))
      ;; needs real swing-side depth (leaf sticking out of the wall);
      ;; sliders/garage/bifold have none and correctly get no hand
      (if (and (> (sch:vlen wdir) 1e-9) (> (abs dpth) 6.0))
        (progn
          (setq swingn (sch:vscale wnorm (if (> dpth 0.0) 1.0 -1.0))
                d (* 0.7 (abs dpth))
                margin 2.0
                doc (vla-get-ActiveDocument (vlax-get-acad-object))
                msp (vla-get-ModelSpace doc)
                p1 (sch:v+ (sch:v+ (sch:pt2 wp1)
                                   (sch:vscale wdir (- a0 margin)))
                           (sch:vscale swingn d))
                p2 (sch:v+ (sch:v+ (sch:pt2 wp1)
                                   (sch:vscale wdir (+ a1 margin)))
                           (sch:vscale swingn d))
                probe (sch:invoke msp 'AddLine
                        (list (list (car p1) (cadr p1) 0.0)
                              (list (car p2) (cadr p2) 0.0))))
          (if probe
            (progn
              (setq raw (sch:invoke probe 'IntersectWith
                          (list vlaDoor 0))) ; acExtendNone
              (sch:catch 'vla-Delete (list probe))
              (setq alongs nil)
              (while (and raw (cddr raw))
                (setq alongs
                  (cons (sch:vdot (sch:v- (list (car raw) (cadr raw))
                                          wp1)
                                  wdir)
                        alongs)
                      raw (cdddr raw)))
              ;; cluster hits within 3.5" - the leaf is a 3D panel so
              ;; its two faces give a tight PAIR of points; the swing
              ;; arc gives a lone point. Doors display partially open,
              ;; and the arc always sweeps toward the STRIKE side, so
              ;; the hinge is on the leaf-cluster side of the arc.
              (setq clusters (sch:cluster-1d alongs 3.5)
                    n (length clusters))
              (setq *sch:probe-last*
                (list (cons "stage" "probed") (cons "a0" a0)
                      (cons "a1" a1) (cons "dpth" dpth)
                      (cons "n" (length alongs))
                      (cons "clusters" clusters)
                      (cons "alongs" alongs)))
              (cond
                ((= n 2)
                 (setq leafC (if (>= (cadr (car clusters))
                                     (cadr (cadr clusters)))
                              (car (car clusters))
                              (car (cadr clusters)))
                       arcC (if (>= (cadr (car clusters))
                                    (cadr (cadr clusters)))
                             (car (cadr clusters))
                             (car (car clusters))))
                 ;; both single points: leaf/arc indistinguishable
                 (if (/= (cadr (car clusters)) (cadr (cadr clusters)))
                   (setq hingeA (if (< leafC arcC) a0 a1)
                         hand (sch:probe-decide a0 a1 hingeA swingn
                                                wdir))))
                ((= n 1)
                 ;; leaf only (arc missed): hinge = nearest edge
                 (setq minI (car (car clusters))
                       hingeA (if (< (abs (- minI a0))
                                     (abs (- minI a1)))
                                a0 a1)
                       hand (sch:probe-decide a0 a1 hingeA swingn
                                              wdir))))))))))
  (if (and (null hand) (null (cdr (assoc "n" *sch:probe-last*))))
    (setq *sch:probe-last*
      (append *sch:probe-last*
              (list (cons "note"
                          (cond ((null bb) "no bbox")
                                ((null wrec) "no wall within 30in")
                                ((<= (abs dpth) 6.0) "no swing depth")
                                (t "no probe result")))))))
  hand)

;; Determine hand of a door vla-object. walls = wall records.
;; Returns "LH" / "RH" / nil.
(defun sch:door-hand (vlaDoor walls / prims arcs lines best bestr ad
                      hinge r a1 a2 wrec wallP1 wallP2 leaf le hand)
  (setq prims (if *sch:use-explode* (sch:explode-copy vlaDoor)))
  (if prims
    (progn
      (foreach o prims
        (cond ((= (sch:objname o) "AcDbArc") (setq arcs (cons o arcs)))
              ((= (sch:objname o) "AcDbLine") (setq lines (cons o lines)))))
      ;; largest arc = swing arc
      (setq bestr 0.0)
      (foreach a arcs
        (setq ad (sch:arc-data a))
        (if (and ad (> (cadr ad) bestr))
          (setq bestr (cadr ad) best ad)))
      (if best
        (progn
          (setq hinge (car best) r (cadr best)
                a1 (caddr best) a2 (cadddr best))
          ;; wall baseline: nearest wall within 12" of hinge
          (setq wrec (sch:nearest-wall hinge walls 12.0))
          (if wrec
            (setq wallP1 (car wrec) wallP2 (cadr wrec))
            ;; fallback: leaf line = line with an endpoint at the hinge,
            ;; length ~ radius; pseudo-baseline is perpendicular to leaf
            (progn
              (foreach l lines
                (setq le (sch:line-ends l))
                (if (and le (null leaf))
                  (cond
                    ((and (< (distance (car le) hinge) (* 0.1 r))
                          (> (distance (cadr le) hinge) (* 0.7 r)))
                     (setq leaf (cadr le)))
                    ((and (< (distance (cadr le) hinge) (* 0.1 r))
                          (> (distance (car le) hinge) (* 0.7 r)))
                     (setq leaf (car le))))))
              (if leaf
                (progn
                  ;; wall direction ~ perpendicular to closed-leaf line is
                  ;; unreliable; use the arc endpoint farthest from leaf tip
                  ;; as the strike, wall dir = hinge->strike
                  (setq wallP1 hinge
                        wallP2 (if (> (distance
                                        (sch:v+ hinge
                                                (list (* r (cos a1))
                                                      (* r (sin a1))))
                                        leaf)
                                      (distance
                                        (sch:v+ hinge
                                                (list (* r (cos a2))
                                                      (* r (sin a2))))
                                        leaf))
                                 (sch:v+ hinge (list (* r (cos a1))
                                                     (* r (sin a1))))
                                 (sch:v+ hinge (list (* r (cos a2))
                                                     (* r (sin a2))))))))))
          (if (and wallP1 wallP2)
            (setq hand (sch:hand-calc hinge r a1 a2 wallP1 wallP2)))))
      (sch:del-ents prims)))
  ;; explode unavailable or inconclusive (BricsCAD): probe method
  (if (null hand)
    (setq hand (sch:door-hand-probe vlaDoor walls)))
  hand)

;;; ------------------------------------------------------------------
;;; Harvest - build item records from the selection
;;; item record: assoc list with string keys:
;;;  "KIND" "DOOR"|"WINDOW"  "MARK" "5"/"A"/""  "CODE" "2668"/""
;;;  "MULT" int  "WIN"/"HIN" real|nil  "HAND" "LH"|"RH"|nil
;;;  "CASED" T|nil  "WALL" "4"|"6"|nil  "STYLE" name  "SRC" tag
;;; ------------------------------------------------------------------

(defun sch:rget (rec k) (cdr (assoc k rec)))

(defun sch:style-name (vlaObj / s)
  (setq s (sch:prop vlaObj 'StyleName))
  (if (null s) (setq s (sch:prop vlaObj 'Style)))
  (if (eq (type s) 'VLA-OBJECT) (setq s (sch:prop s 'Name)))
  (if (eq (type s) 'STR) s ""))

(defun sch:num-prop (vlaObj name / v)
  (setq v (sch:prop vlaObj name))
  (if (eq (type v) 'VARIANT)
    (setq v (sch:catch 'vlax-variant-value (list v))))
  (if (numberp v) v nil))

;; getpropertyvalue-based reader (AutoCAD 2012+/BricsCAD) - reaches
;; data on entities whose COM wrapper exposes nothing (BricsCAD shows
;; only Layer/ObjectName on ACA doors).
(defun sch:gprop (ename name)
  (if (and ename (member "GETPROPERTYVALUE" (atoms-family 1)))
    (sch:catch 'getpropertyvalue (list ename name))))

(defun sch:gprop-num (ename name / v)
  (setq v (sch:gprop ename name))
  (cond ((numberp v) v)
        ((and (eq (type v) 'STR) (distof v)) (distof v))))

;; harvest one AEC object (door/window/opening) -> record
(defun sch:harvest-aec (vlaObj kind cased walls needhand
                        / psets mark code sz mult win hin hand style
                          center wrec wallcls swingval en bb dx dy dz
                          meas snap)
  (setq psets (sch:psets vlaObj)
        style (sch:style-name vlaObj)
        center (sch:bbox-center vlaObj))
  (if (and (not cased) (wcmatch (strcase style) "*ARCH*"))
    (setq cased T))
  (setq mark (sch:trim (sch:val->str
               (sch:pset-val psets "*OBJECTS" "DSLD_NUMBER")))
        code (sch:trim (sch:val->str
               (sch:pset-val psets "*OBJECTS" "STANDARDSIZEDESCRIPTION"))))
  (if (and (/= code "") (setq sz (sch:parse-size code)))
    (setq mult (car sz) win (cadr sz) hin (caddr sz))
    (setq mult 1))
  (if (null win) (setq win (sch:num-prop vlaObj "Width")))
  (if (null hin) (setq hin (sch:num-prop vlaObj "Height")))
  ;; non-COM property channel (BricsCAD's COM wrapper hides AEC data)
  (setq en (sch:catch 'vlax-vla-object->ename (list vlaObj)))
  (if (null win) (setq win (sch:gprop-num en "Width")))
  (if (null hin) (setq hin (sch:gprop-num en "Height")))
  (if (= style "") (setq style (sch:val->str (sch:gprop en "Style"))))
  ;; last resort: measure the bounding box (plan extent = width,
  ;; 3D extent = height), snapped to the nearest inch
  (if (and (null win) (setq bb (sch:bbox vlaObj)))
    (progn
      (setq dx (- (car (cadr bb)) (car (car bb)))
            dy (- (cadr (cadr bb)) (cadr (car bb)))
            dz (- (caddr (cadr bb)) (caddr (car bb))))
      (setq win (float (fix (+ (max dx dy) 0.5))))
      (if (and (null hin) (> dz 12.0))
        (setq hin (float (fix (+ dz 0.5)))))
      (if (> win 0.0) (setq meas T) (setq win nil))))
  ;; snap measured sizes onto the DSLD standard catalog (casing math)
  (if (and meas win)
    (progn
      (setq snap (sch:snap-std kind win hin T cased))
      (if (cadddr snap)
        (setq win (car snap) hin (cadr snap)))))
  ;; hand: property set first (any *SWING*/*HAND* property), else geometry
  (if (and needhand (not cased))
    (progn
      (setq swingval (strcase (sch:val->str
                       (sch:pset-val psets "*OBJECTS" "*SWING*,*HAND*"))))
      (cond ((wcmatch swingval "*LEFT*,LH*") (setq hand "LH"))
            ((wcmatch swingval "*RIGHT*,RH*") (setq hand "RH"))
            (t (setq hand (sch:door-hand vlaObj walls))))))
  (if cased
    (progn
      (setq wrec (if center (sch:nearest-wall center walls 24.0)))
      (setq wallcls (sch:wall-class wrec))))
  (list (cons "KIND" kind) (cons "MARK" mark) (cons "CODE" code)
        (cons "MULT" mult) (cons "WIN" win) (cons "HIN" hin)
        (cons "HAND" hand) (cons "CASED" cased) (cons "WALL" wallcls)
        (cons "STYLE" style) (cons "MEAS" meas) (cons "SRC" "aec")))

;; INSERT-tag fallback: collect tag inserts from a list of
;; (vlaIns . worldPt) pairs. Returns list of records.
(defun sch:harvest-tag-inserts (inserts / bubbles sizes name atts tag val
                                 rec out pt best bestd d sc kind)
  ;; classify
  (foreach ip inserts
    (setq name (strcase (sch:val->str (sch:prop (car ip) 'EffectiveName))))
    (if (= name "") (setq name (strcase (sch:val->str
                                  (sch:prop (car ip) 'Name)))))
    (setq atts (sch:invoke (car ip) 'GetAttributes nil))
    (if atts
      (foreach a atts
        (setq tag (strcase (sch:val->str (sch:prop a 'TagString)))
              val (sch:trim (sch:val->str (sch:prop a 'TextString))))
        (cond
          ((wcmatch tag "*`:DSLD_NUMBER")
           (setq kind (if (wcmatch tag "DOOROBJECTS*") "DOOR" "WINDOW"))
           (setq sc (sch:num-prop (car ip) "XScaleFactor"))
           (setq bubbles (cons (list (cdr ip) val kind
                                     (if sc (abs sc) 1.0))
                               bubbles)))
          ((wcmatch tag "*`:STANDARDSIZEDESCRIPTION,*`:WIDTH")
           (setq kind (if (wcmatch tag "DOOROBJECTS*") "DOOR" "WINDOW"))
           (setq sizes (cons (list (cdr ip) val kind) sizes)))))))
  ;; pair each bubble with nearest same-kind size tag
  (foreach b bubbles
    (setq pt (car b) best nil bestd (* *sch:tagpair-dist* (cadddr b)))
    (foreach s sizes
      (if (= (caddr s) (caddr b))
        (progn
          (setq d (distance pt (car s)))
          (if (< d bestd) (setq bestd d best s)))))
    (setq d (if best (sch:parse-size (cadr best))))
    (setq rec (list (cons "KIND" (caddr b))
                    (cons "MARK" (cadr b))
                    (cons "CODE" (if best (cadr best) ""))
                    (cons "MULT" (if d (car d) 1))
                    (cons "WIN" (if d (cadr d)))
                    (cons "HIN" (if d (caddr d)))
                    (cons "HAND" nil)
                    (cons "CASED" nil) (cons "WALL" nil)
                    (cons "STYLE" "") (cons "SRC" "tag")))
    (setq out (cons rec out)))
  out)

;; xref harvesting: walk an xref insert's block definition with a fast
;; entget/entnext scan (no per-entity COM roundtrips - the old vlax-for
;; walk made huge xrefs unusably slow), transform candidate points to
;; world, keep those inside box p1-p2.
(defun sch:harvest-xref (vlaIns p1 p2 walls / bname bdef e typ nm ip
                          rot sx sy out c wpt kind cased inserts v
                          cnt nd nw kk vf cf inf samplec samplew dxfs
                          cands tagcands cand wr)
  (setq bname (sch:val->str (sch:prop vlaIns 'Name)))
  (setq bdef (tblsearch "BLOCK" bname))
  (setq e (if bdef (cdr (assoc -2 bdef))))
  (setq cnt 0 nd 0 nw 0 kk 0 vf 0 cf 0 inf 0 dxfs nil)
  (if e (setq dxfs (list (cons "start-handle"
                               (cdr (assoc 5 (entget e)))))))
  ;; PASS 1: pure database walk - no COM calls at all (COM use during
  ;; the walk proved able to break entget on AEC customs)
  (while e
    (setq typ (cdr (assoc 0 (entget e)))
          cnt (1+ cnt))
    (if (and (< (length dxfs) 12) (eq (type typ) 'STR)
             (wcmatch typ "AEC*"))
      (setq dxfs (cons typ dxfs)))
    (cond
      ((= typ "AEC_DOOR")
       (setq cands (cons (list e "DOOR" nil) cands)))
      ((= typ "AEC_WINDOW")
       (setq cands (cons (list e "WINDOW" nil) cands)))
      ((= typ "AEC_WINDOW_ASSEMBLY")
       (setq cands (cons (list e "WINDOW" nil) cands)))
      ((= typ "AEC_OPENING")
       (setq cands (cons (list e "DOOR" T) cands)))
      ((= typ "AEC_WALL")
       (setq cands (cons (list e "WALL" nil) cands)))
      ((and (= typ "INSERT")
            (setq nm (cdr (assoc 2 (entget e))))
            (wcmatch (strcase nm) "TK_DOOR_TAG*,TK_WINDOW_TAG*"))
       (setq tagcands (cons (cons e (cdr (assoc 10 (entget e))))
                            tagcands))))
    (setq e (entnext e)))
  (setq kk (length (vl-remove-if '(lambda (x) (= (cadr x) "WALL"))
                                 cands)))
  ;; PASS 2: COM work on the fixed candidate list
  (setq ip (sch:catch 'vlax-safearray->list
             (list (vlax-variant-value (vla-get-InsertionPoint vlaIns))))
        rot (sch:num-prop vlaIns "Rotation")
        sx (sch:num-prop vlaIns "XScaleFactor")
        sy (sch:num-prop vlaIns "YScaleFactor"))
  (if (null rot) (setq rot 0.0))
  (if (null sx) (setq sx 1.0))
  (if (null sy) (setq sy 1.0))
  (if ip
    (progn
      ;; xref walls first, so cased openings inside the xref still
      ;; get their 4"/6" host-wall classification
      (foreach cand cands
        (if (= (cadr cand) "WALL")
          (progn
            (setq v (sch:vla (car cand)))
            (setq wr (if v (sch:wall-record v)))
            (if wr
              (setq walls
                (cons (list (sch:xform-pt (car wr) ip rot sx sy)
                            (sch:xform-pt (cadr wr) ip rot sx sy)
                            (caddr wr))
                      walls))))))
      (foreach cand cands
        (if (/= (cadr cand) "WALL")
          (progn
            (setq kind (cadr cand)
                  cased (caddr cand)
                  v (sch:vla (car cand)))
            (if (null v) (setq vf (1+ vf)))
            (setq c (if v (sch:bbox-center v)))
            (if (and v (null c)) (setq cf (1+ cf)))
            (if c
              (progn
                (setq wpt (sch:xform-pt c ip rot sx sy))
                (if (null samplec) (setq samplec c samplew wpt))
                (if (sch:pt-in-box wpt p1 p2)
                  ;; note: hand detection skipped for xref-resident
                  ;; doors (cannot safely explode inside an xref)
                  (progn
                    (if (= kind "DOOR")
                      (setq nd (1+ nd))
                      (setq nw (1+ nw)))
                    (setq out (cons (sch:harvest-aec v kind cased
                                                     walls nil)
                                    out)))
                  (setq inf (1+ inf))))))))
      (foreach cand tagcands
        (if (cdr cand)
          (progn
            (setq wpt (sch:xform-pt (cdr cand) ip rot sx sy))
            (if (sch:pt-in-box wpt p1 p2)
              (setq inserts (cons (cons (sch:vla (car cand)) wpt)
                                  inserts))))))))
  ;; diagnostics trail for SCHTEST/SCHDIAG
  (setq *sch:xref-last*
    (list (cons "xref" bname) (cons "scanned" cnt)
          (cons "kind-matches" kk) (cons "vla-fail" vf)
          (cons "bbox-fail" cf) (cons "outside-region" inf)
          (cons "ip" ip) (cons "rot" rot) (cons "sx" sx)
          (cons "sample-c" samplec) (cons "sample-wpt" samplew)
          (cons "first-dxf" (reverse dxfs))))
  ;; per-xref readout: shows whether the xref could be scanned at all
  (princ (strcat "\n[SCH]   xref \"" bname "\": " (itoa cnt)
                 " entities scanned, " (itoa nd) " doors / " (itoa nw)
                 " windows inside the region."))
  (if (= cnt 0)
    (princ (strcat "\n[SCH]   (xref \"" bname
                   "\" not walkable - probably demand-loaded. Open that construct and run SCH inside it, or set XLOADCTL to 0 and reload.)")))
  ;; same rule as the top-level harvest: tag records only for kinds
  ;; with no AEC objects found (avoids double-counting tagged doors)
  (if inserts
    (setq out
      (append out
        (vl-remove-if
          '(lambda (r)
             (vl-some '(lambda (q) (and (= (sch:rget q "KIND")
                                           (sch:rget r "KIND"))
                                        (= (sch:rget q "SRC") "aec")))
                      out))
          (sch:harvest-tag-inserts inserts)))))
  out)

;; main harvest: user picks two corners, chooses All, or is in a
;; paper-space layout (sheet drawings that xref interior + exterior
;; constructs together) - then the ENTIRE model space is scanned.
(defun sch:harvest ( / p1 p2 allmode)
  (cond
    ((= (getvar "TILEMODE") 0)
     (princ "\n[SCH] Paper space layout - scanning the ENTIRE model space (all xrefs, interior + exterior together).")
     (setq allmode T
           p1 (list -1.0e12 -1.0e12)
           p2 (list 1.0e12 1.0e12)))
    (t
     (initget "All")
     (setq p1 (getpoint
                "\nSchedule area - first corner of plan region or [All]: "))
     (cond
       ((= p1 "All")
        (princ "\n[SCH] ALL mode - scanning the entire model space. NOTE: constructs holding several plan copies will count every copy; window one copy there instead.")
        (setq allmode T
              p1 (list -1.0e12 -1.0e12)
              p2 (list 1.0e12 1.0e12)))
       (p1 (setq p2 (getcorner p1 "\nOpposite corner: "))))))
  (if (and p1 p2 (listp p1))
    (sch:harvest-core p1 p2 allmode)))

(defun sch:harvest-core (p1 p2 allmode / ss i n e v on walls recs inserts
                           kind cased isxref bd nAd nAw nAo nPx nTag nXr)
  (progn
    (progn
      (princ "\n[SCH] Scanning selection")
      (setq walls (sch:collect-walls))
      (setq nAd 0 nAw 0 nAo 0 nPx 0 nTag 0 nXr 0)
      ;; ALL mode uses a database scan (not view-dependent); region
      ;; mode uses a crossing selection at the picked corners
      (setq ss (if allmode
                 (ssget "_X"
                   '((0 . "AEC_DOOR,AEC_WINDOW,AEC_WINDOW_ASSEMBLY,AEC_OPENING,INSERT,ACAD_PROXY_ENTITY")
                     (410 . "Model")))
                 (ssget "_C" p1 p2
                   '((0 . "AEC_DOOR,AEC_WINDOW,AEC_WINDOW_ASSEMBLY,AEC_OPENING,INSERT,ACAD_PROXY_ENTITY")))))
      (if ss
        (progn
          (setq i 0 n (sslength ss))
          (while (< i n)
            (if (= (rem i 25) 0) (princ "."))
            (setq e (ssname ss i)
                  on (cdr (assoc 0 (entget e)))
                  kind nil cased nil v nil)
            (cond
              ((= on "AEC_DOOR") (setq kind "DOOR" nAd (1+ nAd)))
              ((= on "AEC_WINDOW") (setq kind "WINDOW" nAw (1+ nAw)))
              ((= on "AEC_WINDOW_ASSEMBLY")
               (setq kind "WINDOW" nAw (1+ nAw)))
              ((= on "AEC_OPENING") (setq kind "DOOR" cased T
                                          nAo (1+ nAo)))
              ((= on "ACAD_PROXY_ENTITY") (setq nPx (1+ nPx))))
            (cond
              (kind
               (setq v (sch:vla e))
               ;; swing-hand detection is doors-only
               (if v
                 (setq recs (cons (sch:harvest-aec v kind cased walls
                                                   (= kind "DOOR"))
                                  recs))))
              ((= on "INSERT")
               (setq v (sch:vla e))
               (setq isxref nil)
               (setq bd (sch:catch 'vla-Item
                          (list (vla-get-Blocks
                                  (vla-get-ActiveDocument
                                    (vlax-get-acad-object)))
                                (sch:val->str (sch:prop v 'Name)))))
               (if (and bd (= (sch:prop bd 'IsXRef) :vlax-true))
                 (setq isxref T))
               (cond
                 (isxref
                  (setq nXr (1+ nXr))
                  (setq recs (append recs
                               (sch:harvest-xref v p1 p2 walls))))
                 ((wcmatch (strcase (sch:val->str (sch:prop v 'Name)))
                           "TK_DOOR_TAG*,TK_WINDOW_TAG*")
                  (setq nTag (1+ nTag))
                  (setq inserts
                    (cons (cons v
                                (sch:catch 'vlax-safearray->list
                                  (list (vlax-variant-value
                                          (vla-get-InsertionPoint v)))))
                          inserts))))))
            (setq i (1+ i)))))
      ;; readable breakdown so an empty/partial result explains itself
      (princ (strcat "\n[SCH] Region contents: " (itoa nAd)
                     " AEC doors, " (itoa nAw) " AEC windows, "
                     (itoa nAo) " AEC openings, " (itoa nTag)
                     " tag inserts, " (itoa nXr) " xrefs, "
                     (itoa nPx) " proxy entities."))
      (if (> nPx 0)
        (princ "\n[SCH] NOTE: proxy entities are unreadable here - that data needs AutoCAD Architecture (or AEC object enablers)."))
      ;; use tag-INSERT provider only for kinds with no AEC objects found
      (if inserts
        (progn
          (setq inserts (vl-remove-if '(lambda (x) (null (cdr x))) inserts))
          (setq recs
            (append recs
              (vl-remove-if
                '(lambda (r)
                   (vl-some '(lambda (q) (and (= (sch:rget q "KIND")
                                                 (sch:rget r "KIND"))
                                              (= (sch:rget q "SRC") "aec")))
                            recs))
                (sch:harvest-tag-inserts inserts))))))
      recs)))

;;; ------------------------------------------------------------------
;;; Aggregation
;;; agg row: (mark widthIn heightIn qty lh rh cased wallcls codes notes)
;;; ------------------------------------------------------------------

;; grouping key: mark when readable; otherwise size code, else the
;; measured WxH plus style name - so unmarked doors of different sizes
;; and styles land on separate schedule rows instead of one big group.
(defun sch:agg-key (r / sz)
  (strcat (sch:rget r "KIND") "|"
          (if (/= (sch:rget r "MARK") "") (sch:rget r "MARK")
            (progn
              (setq sz
                (if (/= (sch:rget r "CODE") "") (sch:rget r "CODE")
                  (strcat
                    (if (sch:rget r "WIN")
                      (rtos (sch:rget r "WIN") 2 1) "?")
                    "x"
                    (if (sch:rget r "HIN")
                      (rtos (sch:rget r "HIN") 2 1) "?"))))
              (strcat "?" sz "|"
                      (if (sch:rget r "STYLE") (sch:rget r "STYLE") "")
                      "|"
                      (if (sch:rget r "CASED") "C" "")
                      (if (sch:rget r "WALL") (sch:rget r "WALL") ""))))))

(defun sch:aggregate (recs kind / groups key g out mark win hin qty lh rh
                        cased wall code notes sty mlt meas)
  (setq groups nil)
  (foreach r recs
    (if (= (sch:rget r "KIND") kind)
      (progn
        (setq key (sch:agg-key r)
              g (assoc key groups))
        (if g
          (setq groups (subst (cons key (cons r (cdr g))) g groups))
          (setq groups (cons (cons key (list r)) groups))))))
  (foreach g groups
    (setq mark "" win nil hin nil qty 0 lh 0 rh 0
          cased nil wall nil code "" notes "" sty "" mlt 1 meas nil)
    (foreach r (cdr g)
      (setq qty (+ qty 1))
      (if (sch:rget r "MEAS") (setq meas T))
      (if (and (= sty "") (sch:rget r "STYLE")
               (/= (sch:rget r "STYLE") ""))
        (setq sty (sch:rget r "STYLE")))
      (if (and (sch:rget r "MULT") (> (sch:rget r "MULT") 1))
        (setq mlt (sch:rget r "MULT")))
      (if (and (= mark "") (/= (sch:rget r "MARK") ""))
        (setq mark (sch:rget r "MARK")))
      (if (and (null win) (sch:rget r "WIN"))
        (setq win (* (sch:rget r "WIN")
                     (if (sch:rget r "MULT") (sch:rget r "MULT") 1))))
      (if (and (null hin) (sch:rget r "HIN")) (setq hin (sch:rget r "HIN")))
      (if (= code "") (setq code (sch:rget r "CODE")))
      (if (sch:rget r "CASED") (setq cased T))
      (if (and (null wall) (sch:rget r "WALL")) (setq wall (sch:rget r "WALL")))
      (cond ((= (sch:rget r "HAND") "LH") (setq lh (1+ lh)))
            ((= (sch:rget r "HAND") "RH") (setq rh (1+ rh)))))
    (if (and (= kind "DOOR") (not cased) (< (+ lh rh) qty))
      (setq notes (strcat (itoa (- qty lh rh)) " swing unknown")))
    (if meas
      (setq notes (strcat notes (if (= notes "") "" "; ")
                          "sizes measured from geometry - verify")))
    (setq out (cons (list mark win hin qty lh rh cased wall code notes
                          sty mlt)
                    out)))
  out)

;;; ------------------------------------------------------------------
;;; Table access
;;; ------------------------------------------------------------------

(defun sch:tbl-get (tbl r c / v)
  (setq v (sch:invoke tbl 'GetText (list r c)))
  (if (null v) (setq v (sch:invoke tbl 'GetTextString (list r c))))
  (if (eq (type v) 'STR) v ""))

(defun sch:tbl-set (tbl r c txt / v)
  (setq v (sch:invoke tbl 'SetText (list r c txt)))
  (if (null v) (setq v (sch:invoke tbl 'SetTextString (list r c txt))))
  v)

(defun sch:pick-table (prompt / es v done out)
  (while (not done)
    (setvar "ERRNO" 0)
    (setq es (entsel prompt))
    (cond
      ((and (null es) (= (getvar "ERRNO") 7)) ; missed pick - re-prompt
       (princ "\n[SCH] Nothing there - pick the table or press Enter to skip."))
      ((null es) (setq done T out nil)) ; genuine Enter = skip
      (t
       (setq v (sch:vla (car es)))
       (if (= (sch:objname v) "AcDbTable")
         (setq done T out v)
         (princ "\n[SCH] That is not a table - pick the schedule table or press Enter to cancel.")))))
  out)

;; returns (title headerRowIdx colmap rows cols marks)
;; colmap = assoc of header name -> col index
;; marks = list of (markText . rowIdx) for data rows
(defun sch:table-info (tbl / rows cols r c txt title hdr colmap marks)
  (setq rows (sch:prop tbl 'Rows) cols (sch:prop tbl 'Columns))
  (if (null rows) (setq rows 0))
  (if (null cols) (setq cols 0))
  (setq title (sch:strip-fmt (sch:tbl-get tbl 0 0)))
  ;; find header row
  (setq r 0)
  (while (and (< r rows) (null hdr))
    (if (= (strcase (sch:strip-fmt (sch:tbl-get tbl r 0))) "MARK")
      (setq hdr r))
    (setq r (1+ r)))
  (if hdr
    (progn
      (setq c 0)
      (while (< c cols)
        (setq txt (strcase (sch:strip-fmt (sch:tbl-get tbl hdr c))))
        (if (/= txt "")
          (setq colmap (cons (cons txt c) colmap)))
        (setq c (1+ c)))
      (setq r (1+ hdr))
      (while (< r rows)
        (setq txt (sch:strip-fmt (sch:tbl-get tbl r 0)))
        (setq marks (cons (cons txt r) marks))
        (setq r (1+ r)))))
  (list title hdr colmap rows cols (reverse marks)))

;; SCH-owned tables (on the SCH layer) whose title matches pat AND
;; that have a MARK header row -> list of (tbl info). Legacy charts
;; the routine did not create are ignored on purpose - move a chart
;; onto the SCH layer to hand it over to the routine.
(defun sch:find-tables (pat / ss i tbl info out)
  (setq ss (ssget "_X" (list (cons 0 "ACAD_TABLE")
                             (cons 8 *sch:layer*))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq tbl (sch:vla (ssname ss i))
              info (sch:table-info tbl))
        (if (and (wcmatch (strcase (car info)) pat) (cadr info))
          (setq out (cons (list tbl info) out)))
        (setq i (1+ i)))))
  (reverse out))

;; make sure a layer exists (created color 7 / continuous when new)
(defun sch:ensure-layer (name / doc)
  (if (and name (/= name "") (null (tblsearch "LAYER" name)))
    (progn
      (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
      (sch:catch 'vla-Add (list (vla-get-Layers doc) name))))
  name)

;; create a DSLD-format schedule table at pt (top-left corner).
;; ndata = expected data rows (3 blank spare rows are added).
;; Matches the DSLD sheets: cols MARK|WIDTH|HEIGHT|QTY|DESCRIPTION,
;; widths 27/30/33/21/177, row heights 14/13.33/12, text 6/5.5/4.5,
;; "DSLD Table Style" when the drawing has it. Returns (tbl info).
(defun sch:make-table (title pt ndata / doc msp tbl rows r c widths hdrs)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object))
        msp (vla-get-ModelSpace doc)
        rows (+ 2 ndata 3))
  (setq tbl (sch:catch 'vlax-invoke
              (list msp 'AddTable
                    (list (car pt) (cadr pt) 0.0) rows 5 12.0 57.6)))
  (if tbl
    (progn
      ;; dedicated schedule layer
      (sch:ensure-layer *sch:layer*)
      (sch:catch 'vlax-put-property (list tbl 'Layer *sch:layer*))
      ;; use the DSLD table style if this drawing has it
      (sch:catch 'vlax-put-property (list tbl 'StyleName "DSLD Table Style"))
      (sch:invoke tbl 'SetRowHeight (list 0 14.0))
      (sch:invoke tbl 'SetRowHeight (list 1 13.3333))
      (setq widths '(27.0 30.0 33.0 21.0 177.0) c 0)
      (foreach w widths
        (sch:invoke tbl 'SetColumnWidth (list c w))
        (setq c (1+ c)))
      ;; row types: acDataRow=1 acTitleRow=2 acHeaderRow=4
      (sch:invoke tbl 'SetTextHeight (list 2 6.0))
      (sch:invoke tbl 'SetTextHeight (list 4 5.5))
      (sch:invoke tbl 'SetTextHeight (list 1 4.5))
      ;; data rows middle-center, DESCRIPTION column middle-left
      (sch:invoke tbl 'SetAlignment (list 1 5))
      (setq r 2)
      (while (< r rows)
        (sch:invoke tbl 'SetCellAlignment (list r 4 4))
        (setq r (1+ r)))
      (sch:tbl-set tbl 0 0 title)
      (setq hdrs '("MARK" "WIDTH" "HEIGHT" "QTY" "DESCRIPTION") c 0)
      (foreach h hdrs
        (sch:tbl-set tbl 1 c h)
        (setq c (1+ c)))
      (list tbl (sch:table-info tbl)))))

;; schedule tables in OTHER open drawings (same session) - this is
;; how a scan in the Exterior construct updates the charts that live
;; in the Interior construct. Returns ((tbl info docname) ...).
(defun sch:find-tables-docs (pat / acad active aname docs out name msp
                              info)
  (setq acad (vlax-get-acad-object)
        active (vla-get-ActiveDocument acad)
        aname (strcase (sch:val->str (sch:prop active 'Name)))
        docs (sch:catch 'vla-get-Documents (list acad)))
  (if docs
    (sch:catch
      '(lambda ()
         (vlax-for d docs
           (setq name (sch:val->str (sch:prop d 'Name)))
           (if (/= (strcase name) aname)
             (progn
               (setq msp (sch:catch 'vla-get-ModelSpace (list d)))
               (if msp
                 (sch:catch
                   '(lambda ()
                      (vlax-for o msp
                        (if (and (= (sch:prop o 'ObjectName) "AcDbTable")
                                 (= (strcase (sch:val->str
                                               (sch:prop o 'Layer)))
                                    (strcase *sch:layer*)))
                          (progn
                            (setq info (sch:table-info o))
                            (if (and (wcmatch (strcase (car info)) pat)
                                     (cadr info))
                              (setq out
                                (cons (list o info name) out)))))))
                   nil))))))
      nil))
  (reverse out))

;; locate the schedule table for one kind, or create it where the
;; user points. Exactly one local match -> used automatically;
;; several -> user picks; none locally -> other OPEN drawings are
;; searched (ext scan updates the int construct's charts); still
;; none -> user picks an insertion point for a new one.
;; Returns (tbl info docname-or-nil) or nil.
(defun sch:resolve-table (title pat ndata / cands tbl info pt other)
  (setq cands (sch:find-tables pat))
  (cond
    ((= (length cands) 1)
     (princ (strcat "\n[SCH] Found existing " title " - using it."))
     (append (car cands) (list nil)))
    ((> (length cands) 1)
     (princ (strcat "\n[SCH] " (itoa (length cands))
                    " tables match " title " (multiple schedule sets)."))
     (setq tbl (sch:pick-table
                 (strcat "\nSelect the " title
                         " to fill (Enter to skip): ")))
     (if tbl
       (progn
         (setq info (sch:table-info tbl))
         (if (cadr info)
           (list tbl info nil)
           (progn
             (princ "\n[SCH] That table has no MARK header row - skipped.")
             nil)))))
    (t
     (setq other (sch:find-tables-docs pat))
     (cond
       (other
        (princ (strcat "\n[SCH] Found " title " in open drawing \""
                       (caddr (car other)) "\" - updating it there."))
        (if (> (length other) 1)
          (princ (strcat " (" (itoa (1- (length other)))
                         " further candidate(s) in other drawings ignored)")))
        (car other))
       (t
        (princ (strcat "\n[SCH] No SCH-created " title
                       " found in this or any open drawing (charts the routine did not create are ignored)."))
        (setq pt (getpoint (strcat "\nPick top-left corner for a new "
                                   title " (Enter to skip): ")))
        (if pt
          (append (sch:make-table title pt ndata) (list nil))))))))

;;; ------------------------------------------------------------------
;;; Merge: aggregated data + existing table -> planned rows
;;; plan entry:
;;;  (rowIdx|nil mark wtxt htxt qtyTxt lhTxt rhTxt descTxt|nil flag)
;;;  descTxt nil = leave existing description untouched
;;;  flag: "=" unchanged / "~" changed / "+" new / "!" attention
;;; ------------------------------------------------------------------

(defun sch:col (info name / e)
  (setq e (assoc name (caddr info)))
  (if e (cdr e)))

(defun sch:mark<num (a b) (< (atoi (car a)) (atoi (car b))))
(defun sch:mark<alpha (a b) (< (car a) (car b)))

(defun sch:next-num-mark (used / m)
  (setq m 1)
  (while (member (itoa m) used) (setq m (1+ m)))
  (itoa m))

(defun sch:next-alpha-mark (used / i m)
  (setq i 0 m nil)
  (while (and (< i 26) (null m))
    (if (not (member (chr (+ 65 i)) used))
      (setq m (chr (+ 65 i))))
    (setq i (1+ i)))
  (if m m "?"))

(defun sch:cased-desc (wall)
  (if wall
    (strcat "CASED OPENING - " wall "\" WALL")
    "CASED OPENING"))

;; snap a measured size to the nearest DSLD standard catalog entry.
;; meas T = size came from a bounding box that includes the casing -
;; subtract the trim allowance first (cased openings draw bare).
;; Returns (width height desc T) when snapped, (w h nil nil) if not.
(defun sch:snap-std (kind win hin meas cased / cat w best bestd d)
  (setq cat (if (= kind "WINDOW") *sch:std-windows* *sch:std-doors*)
        w win)
  (if (and meas (not cased))
    (setq w (- w (if (= kind "WINDOW")
                   *sch:win-trim-allow*
                   *sch:door-trim-allow*))))
  (setq bestd (+ *sch:snap-tol* 1e-6))
  (foreach s cat
    (setq d (+ (abs (- (car s) w))
               (if (and hin (cadr s))
                 (* 0.5 (abs (- (cadr s) hin)))
                 0.0)))
    (if (< d bestd) (setq bestd d best s)))
  (if best
    (list (car best) (cadr best) (caddr best) T)
    (list w hin nil nil)))

;; standard DSLD description for a NEW schedule row: explicit style
;; pattern first, then the mined size catalog, then kind defaults.
(defun sch:auto-desc (kind style mult win hin / s out cat)
  (setq s (strcase (if style style "")))
  (foreach pair *sch:desc-map*
    (if (and (null out) (/= s "") (wcmatch s (car pair)))
      (setq out (cdr pair))))
  (if (null out)
    (progn
      (setq cat (if (= kind "WINDOW") *sch:std-windows* *sch:std-doors*))
      (foreach e cat
        (if (and (null out) (numberp win)
                 (equal win (car e) 1.0)
                 (or (null hin) (equal hin (cadr e) 1.0)))
          (setq out (caddr e))))))
  (if (and (null out) (= kind "DOOR") (numberp win) (>= win 90.0))
    (setq out "OVERHEAD GARAGE DOOR")) ; very wide non-cased door
  (if (null out)
    (setq out (if (= kind "WINDOW")
                *sch:desc-window-default*
                *sch:desc-door-default*)))
  (if (and (= kind "DOOR") mult (> mult 1)
           (not (wcmatch (strcase out) "DBL*")))
    (setq out (strcat "DBL. " out)))
  out)

;; first "spare" data row mark: mark pre-filled (like the window
;; table's F/G/H rows) but QTY and WIDTH cells empty; skips marks
;; already taken this run. Returns the mark string or nil.
(defun sch:spare-mark (tbl info taken / out m r)
  (foreach m (nth 5 info)
    (if (and (null out) (/= (car m) "")
             (not (member (car m) taken)))
      (progn
        (setq r (cdr m))
        (if (and (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "QTY"))) "")
                 (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "WIDTH"))) ""))
          (setq out (car m))))))
  out)

;; first completely blank data row (no mark, no qty, no width),
;; excluding row indices in skip. Returns row index or nil.
(defun sch:blank-row (tbl info skip / out m r)
  (foreach m (nth 5 info)
    (if (and (null out) (= (car m) "")
             (not (member (cdr m) skip)))
      (progn
        (setq r (cdr m))
        (if (and (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "QTY"))) "")
                 (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "WIDTH"))) ""))
          (setq out r)))))
  out)

;; find an existing row for an agg row.
;; priority: same mark; else (cased rows) row whose desc contains CASED
;; with same W/H; else same W/H unique.
(defun sch:find-row (agg tbl info / mark marks hit wtxt htxt cw ch cd r
                       cand n)
  (setq mark (car agg) marks (nth 5 info))
  (if (/= mark "")
    (setq hit (assoc mark marks)))
  (if (and (null hit) (cadr agg) (caddr agg))
    (progn
      (setq wtxt (sch:ftin (cadr agg)) htxt (sch:ftin (caddr agg))
            n 0)
      (foreach m marks
        (setq r (cdr m)
              cw (sch:strip-fmt (sch:tbl-get tbl r (sch:col info "WIDTH")))
              ch (sch:strip-fmt (sch:tbl-get tbl r (sch:col info "HEIGHT")))
              cd (strcase (sch:strip-fmt
                    (sch:tbl-get tbl r (sch:col info "DESCRIPTION")))))
        (if (and (= cw wtxt) (= ch htxt)
                 (or (and (nth 6 agg) (wcmatch cd "*CASED*"))
                     (and (not (nth 6 agg)) (not (wcmatch cd "*CASED*")))))
          (progn (setq cand m n (1+ n)))))
      (if (= n 1) (setq hit cand))))
  hit)

;; Build plan for one table.
;; kind "WINDOW"|"DOOR"; aggs = sch:aggregate output.
(defun sch:merge (tbl info aggs kind / plan used marks hit rowidx mark wtxt
                    htxt qty lh rh desc flag curw curh curq curd r
                    sorted sparetaken)
  (setq marks (nth 5 info))
  (foreach m marks
    (if (/= (car m) "") (setq used (cons (car m) used))))
  ;; marks already carried by harvested aggs are taken too - a freshly
  ;; assigned mark must not collide with a tagged opening in this run
  (foreach a aggs
    (if (/= (car a) "") (setq used (cons (car a) used))))
  ;; assign marks to unmarked aggs
  (setq aggs
    (mapcar
      '(lambda (a / hit2 mk sp)
         (if (= (car a) "")
           (progn
             (setq hit2 (sch:find-row a tbl info))
             (setq mk (cond
                        (hit2 (car hit2))
                        ;; pre-filled spare rows (F/G/H style) first
                        ((setq sp (sch:spare-mark tbl info sparetaken))
                         (setq sparetaken (cons sp sparetaken))
                         sp)
                        ((= kind "DOOR") (sch:next-num-mark used))
                        (t (sch:next-alpha-mark used))))
             (setq used (cons mk used))
             (cons mk (cdr a)))
           a))
      aggs))
  ;; sort
  (setq sorted
    (if (= kind "DOOR")
      (vl-sort aggs '(lambda (a b) (< (atoi (car a)) (atoi (car b)))))
      (vl-sort aggs '(lambda (a b) (< (car a) (car b))))))
  (foreach a sorted
    (setq mark (car a)
          wtxt (if (cadr a) (sch:ftin (cadr a)) "")
          htxt (if (caddr a) (sch:ftin (caddr a)) "")
          qty (itoa (nth 3 a))
          ;; "" means THIS SCAN LEARNED NOTHING about swing for this
          ;; row - a cased opening, or every door in the group came in
          ;; through an xref (hand cannot be probed inside an xref) or
          ;; is a garage/slider with no swing. Empty is the signal to
          ;; LEAVE THE CHART ALONE: writing "0" here is what erased the
          ;; correct LH/RH that an earlier scan of the owning construct
          ;; had already written (interior scan, then exterior scan).
          lh (cond ((nth 6 a) "")
                   ((and (= (nth 4 a) 0) (= (nth 5 a) 0)) "")
                   (t (itoa (nth 4 a))))
          rh (cond ((nth 6 a) "")
                   ((and (= (nth 4 a) 0) (= (nth 5 a) 0)) "")
                   (t (itoa (nth 5 a))))
          desc (if (nth 6 a) (sch:cased-desc (nth 7 a)) nil)
          hit (sch:find-row a tbl info)
          flag "+")
    (if hit
      (progn
        (setq rowidx (cdr hit)
              curw (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "WIDTH")))
              curh (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "HEIGHT")))
              curq (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "QTY")))
              curd (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "DESCRIPTION"))))
        ;; keep an existing non-empty description unless cased text changes
        (if (and desc (/= curd "")
                 (= (strcase curd) (strcase desc)))
          (setq desc nil))
        (if (and desc (/= curd "") (not (wcmatch (strcase curd) "*CASED*")))
          (setq desc nil)) ; don't clobber a real description
        ;; fill an EMPTY existing description with the standard text
        (if (and (null desc) (= curd "") (not (nth 6 a)))
          (setq desc (sch:auto-desc kind (nth 10 a) (nth 11 a)
                                    (cadr a) (caddr a))))
        ;; ADD mode: accumulate this scan's counts onto the row
        (if *sch:addmode*
          (progn
            (setq qty (itoa (+ (atoi curq) (nth 3 a))))
            ;; only accumulate swing when this scan actually found some
            ;; - otherwise leave lh/rh as "" so the existing cell is
            ;; kept untouched rather than being rewritten as 0
            (if (and (sch:col info "LH") (not (nth 6 a))
                     (or (> (nth 4 a) 0) (> (nth 5 a) 0)))
              (setq lh (itoa (+ (atoi (sch:strip-fmt
                                        (sch:tbl-get tbl rowidx
                                          (sch:col info "LH"))))
                                (nth 4 a)))
                    rh (itoa (+ (atoi (sch:strip-fmt
                                        (sch:tbl-get tbl rowidx
                                          (sch:col info "RH"))))
                                (nth 5 a)))))))
        (setq flag
          (if (and (or (= wtxt "") (= curw wtxt))
                   (or (= htxt "") (= curh htxt))
                   (= curq qty)
                   (null desc))
            "=" "~")))
      (setq rowidx nil))
    (if (and (= flag "+") (null desc) (not (nth 6 a)))
      (setq desc (sch:auto-desc kind (nth 10 a) (nth 11 a) (cadr a)
                                (caddr a))))
    (setq plan (cons (list rowidx mark wtxt htxt qty lh rh desc flag
                           (nth 9 a))
                     plan)))
  ;; existing data rows with content that were not matched
  (foreach m marks
    (if (and (/= (car m) "")
             (not (vl-some '(lambda (p) (equal (cdr m) (car p))) plan)))
      (progn
        (setq curq (sch:strip-fmt (sch:tbl-get tbl (cdr m)
                                               (sch:col info "QTY"))))
        (if (/= curq "")
          (setq plan (cons (list (cdr m) (car m) "" "" "" "" "" nil "!"
                                 (if *sch:addmode*
                                   "kept (outside this scan)"
                                   "in table, not found in selection"))
                           plan))))))
  (reverse plan))

;;; ------------------------------------------------------------------
;;; Preview dialog (DCL written to temp file)
;;; ------------------------------------------------------------------

;; returns the DCL path, or nil if the temp file cannot be created
(defun sch:dcl-file ( / path f)
  (setq path (vl-filename-mktemp "sch_prev.dcl"))
  (setq f (open path "w"))
  (if (null f)
    nil
    (progn
  (write-line "sch_preview : dialog {" f)
  (write-line "  label = \"SCH - Schedule Fill Preview\";" f)
  (write-line "  : text { key = \"summary\"; width = 110; }" f)
  (write-line "  : boxed_column { label = \"WINDOW SCHEDULE\";" f)
  (write-line "    : list_box { key = \"wlist\"; width = 110; height = 8;" f)
  (write-line "      tabs = \"4 12 22 32 40 46 52\"; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_column { label = \"DOOR SCHEDULE\";" f)
  (write-line "    : list_box { key = \"dlist\"; width = 110; height = 12;" f)
  (write-line "      tabs = \"4 12 22 32 40 46 52\"; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_column { label = \"Notes\";" f)
  (write-line "    : list_box { key = \"nlist\"; width = 110; height = 4; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_radio_row { label = \"LH/RH placement (doors)\"; key = \"handmode\";" f)
  (write-line "    : radio_button { key = \"hm_cols\"; label = \"Insert LH / RH columns after QTY\"; }" f)
  (write-line "    : radio_button { key = \"hm_desc\"; label = \"Append counts to DESCRIPTION\"; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_radio_row { label = \"Counts in matched rows\"; key = \"qtymode\";" f)
  (write-line "    : radio_button { key = \"qm_repl\"; label = \"Replace with this scan\"; }" f)
  (write-line "    : radio_button { key = \"qm_add\"; label = \"Add to existing (scanning another area)\"; }" f)
  (write-line "  }" f)
  (write-line "  : row {" f)
  (write-line "    : button { key = \"accept\"; label = \"Apply to Tables\"; is_default = true; }" f)
  (write-line "    : button { key = \"cancel\"; label = \"Cancel\"; is_cancel = true; }" f)
  (write-line "  }" f)
  (write-line "}" f)
  (close f)
  path)))

(defun sch:plan-line (p / flag)
  (setq flag (nth 8 p))
  (strcat flag "\t" (cadr p) "\t" (caddr p) "\t" (cadddr p) "\t"
          (nth 4 p) "\t" (nth 5 p) "\t" (nth 6 p) "\t"
          (cond ((nth 7 p) (nth 7 p))
                (t "(keep existing)"))))

;; refill the two schedule list_boxes (used live by the mode radios)
(defun sch:preview-fill (wplan dplan)
  (start_list "wlist")
  (foreach p wplan (add_list (sch:plan-line p)))
  (end_list)
  (start_list "dlist")
  (foreach p dplan (add_list (sch:plan-line p)))
  (end_list)
  (princ))

(defun sch:preview (wplanR dplanR wplanA dplanA notes / dclpath dclid ok
                     line)
  (if (null *sch:qtymode*) (setq *sch:qtymode* "replace"))
  ;; stash for the radio action callbacks
  (setq *sch:pw-r* wplanR *sch:pd-r* dplanR
        *sch:pw-a* wplanA *sch:pd-a* dplanA)
  (setq dclpath (sch:dcl-file)
        dclid (if dclpath (load_dialog dclpath) 0)
        ok nil)
  (if (and dclid (> dclid 0) (new_dialog "sch_preview" dclid))
    (progn
      (set_tile "summary"
        (strcat "  " (itoa (length wplanR)) " window rows, "
                (itoa (length dplanR)) " door rows.   "
                "Flags:  + new row   ~ changed   = unchanged   ! kept"
                "   |   MARK  WIDTH  HEIGHT  QTY  LH  RH  DESCRIPTION"))
      (if (= *sch:qtymode* "add")
        (sch:preview-fill wplanA dplanA)
        (sch:preview-fill wplanR dplanR))
      (start_list "nlist")
      (if notes
        (foreach x notes (add_list x))
        (add_list "(none)"))
      (end_list)
      (set_tile (if (= *sch:handmode* "desc") "hm_desc" "hm_cols") "1")
      (set_tile (if (= *sch:qtymode* "add") "qm_add" "qm_repl") "1")
      (action_tile "hm_cols" "(setq *sch:handmode* \"cols\")")
      (action_tile "hm_desc" "(setq *sch:handmode* \"desc\")")
      (action_tile "qm_repl"
        "(setq *sch:qtymode* \"replace\") (sch:preview-fill *sch:pw-r* *sch:pd-r*)")
      (action_tile "qm_add"
        "(setq *sch:qtymode* \"add\") (sch:preview-fill *sch:pw-a* *sch:pd-a*)")
      (action_tile "accept" "(done_dialog 1)")
      (action_tile "cancel" "(done_dialog 0)")
      (setq ok (= (start_dialog) 1)))
    (progn
      ;; DCL failed - fall back to command-line preview + confirm
      (princ "\n--- SCH preview (dialog unavailable) ---")
      (princ "\nWINDOW SCHEDULE:")
      (foreach p wplanR
        (setq line (sch:plan-line p))
        (princ (strcat "\n  " (vl-string-translate "\t" " " line))))
      (princ "\nDOOR SCHEDULE:")
      (foreach p dplanR
        (setq line (sch:plan-line p))
        (princ (strcat "\n  " (vl-string-translate "\t" " " line))))
      (foreach x notes (princ (strcat "\n  NOTE: " x)))
      (initget "Replace Add")
      (setq line (getkword
        "\nCounts in matched rows [Replace/Add] <Replace>: "))
      (setq *sch:qtymode* (if (= line "Add") "add" "replace"))
      (initget "Yes No")
      (setq ok (= (getkword "\nApply to tables? [Yes/No] <No>: ") "Yes"))))
  ;; unload whenever a dialog was actually loaded (even if new_dialog
  ;; failed and we fell back to the command line)
  (if (and dclid (> dclid 0)) (unload_dialog dclid))
  (if dclpath (vl-file-delete dclpath))
  ok)

;;; ------------------------------------------------------------------
;;; Apply
;;; ------------------------------------------------------------------

;; ensure LH/RH columns exist on the door table (cols mode).
;; returns updated info.
(defun sch:ensure-hand-cols (tbl info / qtycol hdr r)
  (setq qtycol (sch:col info "QTY") hdr (cadr info))
  (if (and qtycol hdr (null (sch:col info "LH")))
    (progn
      (sch:invoke tbl 'InsertColumns (list (1+ qtycol) 21.0 2))
      (sch:tbl-set tbl hdr (1+ qtycol) "LH")
      (sch:tbl-set tbl hdr (+ 2 qtycol) "RH")
      (sch:catch 'vlax-invoke
        (list tbl 'SetColumnWidth (1+ qtycol) 21.0))
      (sch:catch 'vlax-invoke
        (list tbl 'SetColumnWidth (+ 2 qtycol) 21.0))
      (setq info (sch:table-info tbl))))
  info)

;; append a new data row at the bottom; returns new row index or nil.
;; InsertRows is a void method - success is verified by the row count
;; actually growing, never by the (always-nil) return value.
(defun sch:append-row (tbl info / rows h newrows)
  (setq rows (nth 3 info))
  (setq h (sch:invoke tbl 'GetRowHeight (list (1- rows))))
  (if (null h) (setq h 12.0))
  (sch:invoke tbl 'InsertRows (list rows h 1))
  (setq newrows (sch:prop tbl 'Rows))
  (if (and newrows (> newrows rows)) rows))

;; remove a previously appended "N LH / N RH" clause from a description
;; so re-runs refresh the counts instead of keeping stale ones
(defun sch:strip-hand (s / i j)
  (if (setq i (vl-string-search " LH / " s)) ; 0-based match position
    (progn
      (setq j i) ; 1-based index of the char just before the match
      (while (and (> j 0) (wcmatch (substr s j 1) "#"))
        (setq j (1- j))) ; walk back over the LH count digits
      (vl-string-right-trim " -" (substr s 1 j)))
    s))

(defun sch:apply-plan (tbl info plan kind / r p rowidx desc lhc rhc
                         written handcols newrows)
  (setq written 0)
  (setq handcols (and (= kind "DOOR") (= *sch:handmode* "cols")))
  (if handcols (setq info (sch:ensure-hand-cols tbl info)))
  (if (= kind "DOOR")
    (sch:tr (strcat "apply-plan DOOR handmode="
                    (vl-princ-to-string *sch:handmode*)
                    " handcols=" (if handcols "T" "nil")
                    " LHcol=" (vl-princ-to-string (sch:col info "LH"))
                    " RHcol=" (vl-princ-to-string (sch:col info "RH"))
                    " rows=" (itoa (length plan)))))
  (foreach p plan
    (if (/= (nth 8 p) "!")
      (progn
        (setq rowidx (car p))
        (if (null rowidx)
          (progn
            ;; consume a blank spare row first, only then grow the table
            (setq rowidx (sch:blank-row tbl info newrows))
            (if (null rowidx)
              (setq rowidx (sch:append-row tbl info)
                    info (if rowidx (sch:table-info tbl) info)))
            (if rowidx (setq newrows (cons rowidx newrows)))))
        (if rowidx
          (progn
            (sch:tbl-set tbl rowidx (sch:col info "MARK") (cadr p))
            (if (/= (caddr p) "")
              (sch:tbl-set tbl rowidx (sch:col info "WIDTH") (caddr p)))
            (if (/= (cadddr p) "")
              (sch:tbl-set tbl rowidx (sch:col info "HEIGHT") (cadddr p)))
            (sch:tbl-set tbl rowidx (sch:col info "QTY") (nth 4 p))
            ;; write swing ONLY when this scan actually determined it.
            ;; (nth 5 p) = "" means unknown - skip, so a rescan that
            ;; cannot see the swing (e.g. the doors arrived through an
            ;; xref) preserves the LH/RH a previous scan got right
            ;; instead of zeroing it.
            (if (and handcols (sch:col info "LH") (/= (nth 5 p) ""))
              (progn
                (sch:tbl-set tbl rowidx (sch:col info "LH") (nth 5 p))
                (sch:tbl-set tbl rowidx (sch:col info "RH") (nth 6 p))))
            (if (= kind "DOOR")
              (sch:tr (strcat "  row mark=" (vl-princ-to-string (cadr p))
                              " lh=" (vl-princ-to-string (nth 5 p))
                              " rh=" (vl-princ-to-string (nth 6 p))
                              " wrote=" (if (and handcols (sch:col info "LH"))
                                          "y" "n"))))
            (setq desc (nth 7 p))
            (if (and (= kind "DOOR") (= *sch:handmode* "desc")
                     (or (/= (nth 5 p) "") (/= (nth 6 p) ""))
                     (or (/= (nth 5 p) "0") (/= (nth 6 p) "0")))
              (progn
                (if (null desc)
                  (setq desc (sch:strip-fmt
                               (sch:tbl-get tbl rowidx
                                            (sch:col info "DESCRIPTION")))))
                (setq desc (sch:strip-hand desc))
                (setq desc (strcat desc
                             (if (= desc "") "" " - ")
                             (nth 5 p) " LH / " (nth 6 p) " RH"))))
            (if desc
              (sch:tbl-set tbl rowidx (sch:col info "DESCRIPTION") desc))
            (setq written (1+ written)))))))
  written)

;;; ------------------------------------------------------------------
;;; c:SCH - main command
;;; ------------------------------------------------------------------

(defun c:SCH ( / doc recs waggs daggs wres dres wtbl dtbl winfo dinfo
                 wplan dplan wplanr dplanr wplana dplana notes ok n
                 oldecho *error*)
  (defun *error* (msg)
    (if doc (sch:catch 'vla-EndUndoMark (list doc)))
    (if oldecho (setvar "CMDECHO" oldecho))
    (if (and msg (not (wcmatch (strcase msg) "*BREAK*,*CANCEL*,*EXIT*")))
      (princ (strcat "\n[SCH] Error: " msg)))
    (princ))
  (princ (strcat "\n[SCH v" *sch:version* "]"))
  (sch:trace-init)
  (sch:tr (strcat "gates: aecx=" (if *sch:use-aecx* "ON" "OFF")
                  "  explode=" (if *sch:use-explode* "ON" "OFF")))
  (setq oldecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  (sch:tr "STEP: get ActiveDocument")
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (sch:catch 'vla-StartUndoMark (list doc))
  (sch:tr "STEP: harvest (select region)")
  (setq recs (sch:harvest))
  (sch:tr (strcat "STEP: harvest done, "
                  (itoa (length recs)) " records"))
  (cond
    ((null recs)
     (princ "\n[SCH] Nothing found. Select a region containing doors/windows (AEC objects or TK_ tag blocks)."))
    (t
     (princ (strcat "\n[SCH] Found " (itoa (length recs)) " openings ("
                    (itoa (length (vl-remove-if-not
                                    '(lambda (r) (= (sch:rget r "KIND")
                                                    "DOOR"))
                                    recs)))
                    " door / "
                    (itoa (length (vl-remove-if-not
                                    '(lambda (r) (= (sch:rget r "KIND")
                                                    "WINDOW"))
                                    recs)))
                    " window)."))
     (setq waggs (sch:aggregate recs "WINDOW")
           daggs (sch:aggregate recs "DOOR"))
     ;; locate / create the schedule tables (auto-find when unique,
     ;; pick when several sets, create at a user point when missing)
     (if waggs
       (setq wres (sch:resolve-table "WINDOW SCHEDULE" "*WINDOW*"
                                     (length waggs)))
       (princ "\n[SCH] No windows in the selection - window schedule skipped."))
     (if daggs
       (setq dres (sch:resolve-table "DOOR SCHEDULE" "*DOOR*"
                                     (length daggs)))
       (princ "\n[SCH] No doors in the selection - door schedule skipped."))
     (setq wtbl (car wres) winfo (cadr wres)
           dtbl (car dres) dinfo (cadr dres))
     (if (and (null wtbl) (null dtbl))
       (princ "\n[SCH] No schedule tables available - cancelled.")
       (progn
         ;; two plans per table: Replace-counts and Add-counts; the
         ;; preview radio picks which one gets applied
         (setq *sch:addmode* nil)
         (if winfo (setq wplanr (sch:merge wtbl winfo waggs "WINDOW")))
         (if dinfo (setq dplanr (sch:merge dtbl dinfo daggs "DOOR")))
         (setq *sch:addmode* T)
         (if winfo (setq wplana (sch:merge wtbl winfo waggs "WINDOW")))
         (if dinfo (setq dplana (sch:merge dtbl dinfo daggs "DOOR")))
         (setq *sch:addmode* nil)
         (setq wplan wplanr dplan dplanr)
         (foreach p (append wplan dplan)
           (if (and (nth 9 p) (/= (nth 9 p) ""))
             (setq notes (cons (strcat "Mark " (cadr p) ": " (nth 9 p))
                               notes))))
         (if (vl-some '(lambda (r) (= (sch:rget r "MARK") "")) recs)
           (setq notes
             (cons "Some openings have no readable mark - rows grouped by size/style, marks auto-assigned."
                   notes)))
         (foreach r recs
           (if (and (= (sch:rget r "SRC") "tag")
                    (= (sch:rget r "CODE") ""))
             (setq notes (cons (strcat "Tag mark " (sch:rget r "MARK")
                                       ": no size tag paired")
                               notes))))
         (if (and wres (caddr wres))
           (setq notes (cons (strcat "Window schedule is in open drawing \""
                                     (caddr wres)
                                     "\" - it updates there (undo there too).")
                             notes)))
         (if (and dres (caddr dres))
           (setq notes (cons (strcat "Door schedule is in open drawing \""
                                     (caddr dres)
                                     "\" - it updates there (undo there too).")
                             notes)))
         (setq notes (reverse notes))
         (if (null *sch:handmode*) (setq *sch:handmode* "cols"))
         (setq ok (sch:preview (if wplanr wplanr '())
                               (if dplanr dplanr '())
                               (if wplana wplana '())
                               (if dplana dplana '())
                               notes))
         (if (= *sch:qtymode* "add")
           (setq wplan wplana dplan dplana))
         (if ok
           (progn
             (setq n 0)
             (if (and wtbl wplan)
               (setq n (+ n (sch:apply-plan wtbl winfo wplan "WINDOW"))))
             (if (and dtbl dplan)
               (setq n (+ n (sch:apply-plan dtbl dinfo dplan "DOOR"))))
             (princ (strcat "\n[SCH] Done - " (itoa n) " rows written.")))
           (princ "\n[SCH] Cancelled - tables unchanged."))))))
  (sch:catch 'vla-EndUndoMark (list doc))
  (setvar "CMDECHO" oldecho)
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHDIAG - diagnostics
;;; ------------------------------------------------------------------

;; f kept for signature compatibility but IGNORED: every line is
;; opened/appended/closed individually so the report file survives an
;; AutoCAD crash - the last line on disk shows the step that killed it.
(defun sch:diag-out (f msg / fh)
  (princ (strcat "\n" msg))
  (if *sch:diag-path*
    (progn
      (setq fh (open *sch:diag-path* "a"))
      (if fh (progn (write-line msg fh) (close fh)))))
  (princ))

(defun sch:diag-count (f label filt / ss)
  (setq ss (ssget "_X" filt))
  (sch:diag-out f (strcat "  " label ": "
                          (if ss (itoa (sslength ss)) "0"))))

(defun sch:diag-props (f obj / names v)
  (if (not (and obj (eq (type obj) 'VLA-OBJECT)))
    (sch:diag-out f "    (no VLA object - properties unavailable)")
    (progn
  (setq names '("Width" "Height" "Rise" "Leaf" "StyleName" "Style"
                "Location" "InsertionPoint" "Position" "Normal" "Rotation"
                "OpeningPercent" "Swing" "SwingDirection" "Hand" "Handing"
                "Measure" "MeasureTo" "Length" "StartPoint" "EndPoint"
                "Justification" "BaseHeight" "Name" "EffectiveName"
                "Description" "Layer" "ObjectName"))
  (foreach n names
    (if (vlax-property-available-p obj n)
      (progn
        (setq v (sch:catch 'vlax-get-property (list obj n)))
        (if (eq (type v) 'VARIANT)
          (setq v (sch:catch 'vlax-variant-value (list v))))
        (sch:diag-out f
          (strcat "    ." n " = "
                  (cond ((eq (type v) 'STR) v)
                        ((numberp v) (rtos v 2 4))
                        ((eq (type v) 'VLA-OBJECT)
                         (strcat "<object "
                                 (sch:val->str (sch:prop v 'Name)) ">"))
                        ((and v (eq (type v) 'SAFEARRAY))
                         (vl-princ-to-string
                           (sch:catch 'vlax-safearray->list (list v))))
                        (v (vl-princ-to-string v))
                        (t "nil"))))))))))

;; probe getpropertyvalue with likely AEC property names
(defun sch:diag-gprops (f ename / v hits)
  (if (member "GETPROPERTYVALUE" (atoms-family 1))
    (progn
      (setq hits 0)
      (foreach n '("Width" "Height" "Rise" "Style" "StyleName"
                   "Description" "DoorWidth" "DoorHeight" "LeafWidth"
                   "FrameWidth" "OpenPercent" "SwingAngle" "Measure"
                   "WallWidth" "BaseHeight" "Length" "Elevation")
        (setq v (sch:catch 'getpropertyvalue (list ename n)))
        (if v
          (progn
            (setq hits (1+ hits))
            (sch:diag-out f (strcat "    gpv ." n " = "
                                    (vl-princ-to-string v))))))
      (if (= hits 0)
        (sch:diag-out f "    (getpropertyvalue returned nothing)")))
    (sch:diag-out f "    (getpropertyvalue not available)"))
  (princ))

(defun sch:diag-psets (f obj / psets)
  (setq psets (sch:psets obj))
  (if psets
    (foreach ps psets
      (sch:diag-out f (strcat "    property set [" (car ps) "]"))
      (foreach pr (cdr ps)
        (sch:diag-out f (strcat "      " (car pr) " = " (cdr pr)))))
    (sch:diag-out f
      (if (sch:sched-app)
        "    (no property sets returned for this object)"
        "    (AecX.AecScheduleApplication NOT available - property sets unreadable)"))))

;; dump one entity's entget (capped) - used for property-set objects
(defun sch:diag-dumpent (f ename indent / ed i)
  (setq ed (sch:catch 'entget (list ename)) i 0)
  (foreach g ed
    (if (< i 60)
      (sch:diag-out f (strcat indent (vl-princ-to-string g))))
    (setq i (1+ i)))
  (if (>= i 60) (sch:diag-out f (strcat indent "...(truncated)")))
  (princ))

;; walk the extension dictionary two levels deep - this is where ACA
;; property sets live (AEC_PROPERTY_SETS dictionary), and the raw
;; entget of those objects shows how to read DSLD_NUMBER etc. without
;; the AecX COM interface.
(defun sch:diag-xdict (f ename / ed xd name name2 sub subed g g2)
  (setq ed (entget ename)
        xd (cdr (assoc 360 ed)))
  (if (null xd)
    (sch:diag-out f "    (no extension dictionary)")
    (progn
      (sch:diag-out f "    extension dictionary entries:")
      (foreach g (entget xd)
        (cond
          ((= (car g) 3) (setq name (cdr g)))
          ((member (car g) '(350 360 340))
           (setq sub (cdr g)
                 subed (sch:catch 'entget (list sub)))
           (sch:diag-out f (strcat "      [" (if name name "?")
                                   "] type="
                                   (if subed (cdr (assoc 0 subed)) "?")))
           (if (and subed (= (cdr (assoc 0 subed)) "DICTIONARY"))
             (progn
               (setq name2 nil)
               (foreach g2 subed
                 (cond
                   ((= (car g2) 3) (setq name2 (cdr g2)))
                   ((member (car g2) '(350 360 340))
                    (sch:diag-out f (strcat "        {"
                                            (if name2 name2 "?") "}"))
                    (sch:diag-dumpent f (cdr g2) "          ")))))
             (if (and subed
                      (wcmatch (strcase (if name name "")) "*PROP*,*AEC*"))
               (sch:diag-dumpent f sub "        "))))))))
  (princ))

(defun c:SCHDIAG ( / fh es v on ename walls hand prims done ss i tbl
                     info oldecho kw bb doc *error*)
  (defun *error* (msg)
    (if doc (sch:catch 'vla-EndUndoMark (list doc)))
    (if oldecho (setvar "CMDECHO" oldecho))
    (if (and msg (not (wcmatch (strcase msg) "*BREAK*,*CANCEL*,*EXIT*")))
      (princ (strcat "\n[SCHDIAG] Error: " msg)))
    (princ))
  (princ (strcat "\n[SCH v" *sch:version* "]"))
  (setq doc (sch:catch 'vla-get-ActiveDocument
                       (list (vlax-get-acad-object))))
  (if doc (sch:catch 'vla-StartUndoMark (list doc)))
  (setq oldecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  ;; report path: next to the DWG, else temp folder
  (setq *sch:diag-path* (strcat (getvar "DWGPREFIX") "SCHDIAG-report.txt"))
  (setq fh (open *sch:diag-path* "a"))
  (if fh
    (close fh)
    (setq *sch:diag-path*
      (strcat (getvar "TEMPPREFIX") "SCHDIAG-report.txt")))
  ;; opt-in gates for the two crash-prone subsystems
  (initget "Yes No")
  (setq kw (getkword
    "\nTest AecX property-set interface (COM)? [Yes/No] <Yes>: "))
  (setq *sch:use-aecx* (/= kw "No"))
  (initget "Yes No")
  (setq kw (getkword
    "\nTest door explode / swing detection? [Yes/No] <Yes>: "))
  (setq *sch:use-explode* (/= kw "No"))
  (sch:diag-out nil "==========================================================")
  (sch:diag-out nil (strcat "SCHDIAG v1.8  (SCH.lsp v" *sch:version*
                            ")  dwg: " (getvar "DWGNAME")
                            "  date: " (rtos (getvar "CDATE") 2 6)))
  (sch:diag-out nil (strcat "  product: " (getvar "ACADVER")
                            "  aecx-gate: " (if *sch:use-aecx* "ON" "OFF")
                            "  explode-gate: "
                            (if *sch:use-explode* "ON" "OFF")))
  (sch:diag-out nil "STEP: census of AEC objects (ssget)...")
  (sch:diag-count nil "AEC doors" '((0 . "AEC_DOOR")))
  (sch:diag-count nil "AEC windows" '((0 . "AEC_WINDOW")))
  (sch:diag-count nil "AEC window assemblies" '((0 . "AEC_WINDOW_ASSEMBLY")))
  (sch:diag-count nil "AEC openings" '((0 . "AEC_OPENING")))
  (sch:diag-count nil "AEC walls" '((0 . "AEC_WALL")))
  (sch:diag-count nil "AEC mvblock refs (tags)" '((0 . "AEC_MVBLOCK_REF")))
  (sch:diag-count nil "TK_ tag INSERTs" '((0 . "INSERT") (2 . "TK_*")))
  (sch:diag-count nil "ACAD tables" '((0 . "ACAD_TABLE")))
  (if *sch:use-aecx*
    (progn
      (sch:diag-out nil
        "STEP: probing AecX.AecScheduleApplication (if AutoCAD dies HERE, rerun and answer No to the AecX question)...")
      (sch:diag-out nil
        (strcat "  AecX schedule app: "
                (if (sch:sched-app)
                  (strcat "OK (AecX.AecScheduleApplication"
                          (if *sch:schedapp-ver* *sch:schedapp-ver* "")
                          ")")
                  "NOT AVAILABLE")))))
  (sch:diag-out nil "STEP: reading ACAD table titles...")
  (setq ss (ssget "_X" '((0 . "ACAD_TABLE"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq tbl (sch:vla (ssname ss i))
              info (sch:table-info tbl))
        (sch:diag-out nil
          (strcat "  table " (itoa (1+ i)) ": \"" (car info) "\"  rows="
                  (itoa (nth 3 info)) " cols=" (itoa (nth 4 info))
                  (if (cadr info)
                    (strcat "  header row=" (itoa (cadr info)))
                    "  (no MARK header)")))
        (setq i (1+ i)))))
  ;; per-entity inspection loop
  (sch:diag-out nil "-- entity inspection (pick doors, windows, openings, walls, tags; Enter to finish) --")
  (setq done nil)
  (while (not done)
    (setq es (entsel "\nSCHDIAG - select an entity to inspect (Enter to finish): "))
    (if (null es)
      (setq done T)
      (progn
        (setq ename (car es) v (sch:vla ename) on (sch:objname v))
        (sch:diag-out nil (strcat "  ENTITY " on
                                  "  layer=" (sch:val->str (sch:prop v 'Layer))
                                  "  handle=" (sch:val->str (sch:prop v 'Handle))))
        (sch:diag-out nil (strcat "    dxf type: "
                                  (cdr (assoc 0 (entget ename)))))
        (sch:diag-out nil "STEP: raw entget dump...")
        (sch:diag-dumpent nil ename "      ")
        (sch:diag-out nil "STEP: ActiveX property probe...")
        (sch:diag-props nil v)
        (sch:diag-out nil "STEP: getpropertyvalue probe...")
        (sch:diag-gprops nil ename)
        (setq bb (sch:bbox v))
        (if bb
          (sch:diag-out nil
            (strcat "    bbox dx/dy/dz = "
                    (rtos (- (car (cadr bb)) (car (car bb))) 2 2) " / "
                    (rtos (- (cadr (cadr bb)) (cadr (car bb))) 2 2) " / "
                    (rtos (- (caddr (cadr bb)) (caddr (car bb))) 2 2)))
          (sch:diag-out nil "    (no bounding box)"))
        (if *sch:use-aecx*
          (progn
            (sch:diag-out nil
              "STEP: property sets via AecX (if AutoCAD dies HERE, rerun with AecX = No)...")
            (sch:diag-psets nil v)))
        (sch:diag-out nil "STEP: extension dictionary...")
        (sch:diag-xdict nil ename)
        ;; door-specific: explode test + hand
        (if (and *sch:use-explode* (wcmatch on "AecDbDoor,AecDbOpening"))
          (progn
            (sch:diag-out nil
              "STEP: explode/swing test (if AutoCAD dies HERE, rerun with explode = No)...")
            (setq prims (sch:explode-copy v))
            (if prims
              (progn
                (foreach o prims
                  (sch:diag-out nil (strcat "      -> " (sch:objname o))))
                (sch:del-ents prims))
              (sch:diag-out nil "      (explode produced nothing / failed)"))
            (if (null walls) (setq walls (sch:collect-walls)))
            (setq hand (sch:door-hand v walls))
            (sch:diag-out nil (strcat "    computed hand: "
                                      (if hand hand "UNKNOWN")))
            (setq hand (sch:door-hand-probe v walls))
            (sch:diag-out nil (strcat "    probe-based hand: "
                                      (if hand hand "UNKNOWN")))))
        (if (= on "AecDbWall")
          (progn
            (sch:diag-out nil "STEP: wall record...")
            (sch:diag-out nil
              (strcat "    wall record: "
                      (vl-princ-to-string (sch:wall-record v)))))))))
  (sch:diag-out nil "-- end of SCHDIAG run (completed normally) --")
  (if doc (sch:catch 'vla-EndUndoMark (list doc)))
  (setvar "CMDECHO" oldecho)
  (princ (strcat "\n[SCHDIAG] Report at: " *sch:diag-path*))
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHCHECK - automated end-to-end swing pipeline check. Simulates
;;; the ENTIRE scan non-interactively (no picks, no dialogs, no
;;; writes): harvest all of model space -> aggregate -> locate the
;;; door schedule (this drawing or any open drawing) -> simulate the
;;; merge -> report where LH/RH survives or drops, with a VERDICT
;;; line naming the failing stage. Writes SCH-check-report.txt beside
;;; the drawing. Run it in the drawing you would scan (e.g. the
;;; exterior construct) with the chart drawing also open.
;;; ------------------------------------------------------------------

(defun sch:chk (msg / fh)
  (if *sch:chk-path*
    (progn
      (setq fh (open *sch:chk-path* "a"))
      (if fh (progn (write-line msg fh) (close fh)))))
  (princ))

;; NOTE: "read-only" means it never writes to the CHARTS. The harvest
;; path runs the swing probe, which creates and deletes one temporary
;; line in model space (sch:door-hand-probe). It is therefore bracketed
;; in an undo mark so a failed cleanup is always recoverable with one U.
(defun c:SCHCHECK ( / recs daggs dres tbl info plan doors nh nnil
                     agglh aggrh planlh planrh lhcol verdict fh p a r
                     hnd sty doc)
  (princ (strcat "\n[SCH v" *sch:version* "] pipeline check"))
  (setq doc (sch:catch 'vla-get-ActiveDocument
                       (list (vlax-get-acad-object))))
  (if doc (sch:catch 'vla-StartUndoMark (list doc)))
  (setq *sch:chk-path* (strcat (getvar "DWGPREFIX") "SCH-check-report.txt"))
  (setq fh (open *sch:chk-path* "w"))
  (if fh (progn (write-line (strcat "SCHCHECK v" *sch:version*
                                    "  dwg=" (getvar "DWGNAME")) fh)
                (close fh)))
  ;; ---- stage 1: harvest (all model space, non-interactive) ---------
  (sch:chk "STAGE 1: harvest (all model space)")
  (setq recs (sch:harvest-core (list -1.0e12 -1.0e12)
                               (list 1.0e12 1.0e12) T))
  (setq doors (vl-remove-if-not
                '(lambda (r) (and (= (sch:rget r "KIND") "DOOR")
                                  (not (sch:rget r "CASED"))))
                recs))
  (setq nh 0 nnil 0)
  (foreach r doors
    (setq hnd (sch:rget r "HAND") sty (sch:rget r "STYLE"))
    (if hnd (setq nh (1+ nh)) (setq nnil (1+ nnil)))
    (sch:chk (strcat "  door style=" sty
                     " mark=" (vl-princ-to-string (sch:rget r "MARK"))
                     " hand=" (if hnd hnd "nil")
                     " src=" (vl-princ-to-string (sch:rget r "SRC")))))
  (sch:chk (strcat "  doors=" (itoa (length doors))
                   "  with-hand=" (itoa nh) "  no-hand=" (itoa nnil)))
  ;; ---- stage 2: aggregate ------------------------------------------
  (sch:chk "STAGE 2: aggregate")
  (setq daggs (sch:aggregate recs "DOOR"))
  (setq agglh 0 aggrh 0)
  (foreach a daggs
    (setq agglh (+ agglh (nth 4 a)) aggrh (+ aggrh (nth 5 a)))
    (sch:chk (strcat "  agg mark=" (vl-princ-to-string (car a))
                     " qty=" (itoa (nth 3 a))
                     " lh=" (itoa (nth 4 a))
                     " rh=" (itoa (nth 5 a))
                     (if (nth 6 a) " CASED" ""))))
  (sch:chk (strcat "  total lh=" (itoa agglh) " rh=" (itoa aggrh)))
  ;; ---- stage 3: locate door schedule (read-only resolve) -----------
  (sch:chk "STAGE 3: locate door schedule")
  (setq dres (car (sch:find-tables "*DOOR*")))
  (if dres
    (sch:chk "  found in THIS drawing")
    (progn
      (setq dres (car (sch:find-tables-docs "*DOOR*")))
      (if dres
        (sch:chk (strcat "  found in open drawing \"" (caddr dres) "\"")))))
  (cond
    ((null dres)
     (sch:chk "  NO door schedule found in this or any open drawing"))
    (t
     (setq tbl (car dres) info (cadr dres))
     (sch:chk (strcat "  header-row=" (vl-princ-to-string (cadr info))
                      "  columns=" (vl-princ-to-string (caddr info))))
     (setq lhcol (sch:col info "LH"))
     (sch:chk (strcat "  LH-col=" (vl-princ-to-string lhcol)
                      "  RH-col=" (vl-princ-to-string (sch:col info "RH"))
                      "  handmode=" (vl-princ-to-string *sch:handmode*)))
     ;; ---- stage 4: simulate merge (read-only) ----------------------
     (sch:chk "STAGE 4: merge simulation (replace mode)")
     (setq *sch:addmode* nil)
     (setq plan (sch:merge tbl info daggs "DOOR"))
     (setq planlh 0 planrh 0)
     (foreach p plan
       (setq planlh (+ planlh (atoi (nth 5 p)))
             planrh (+ planrh (atoi (nth 6 p))))
       (sch:chk (strcat "  plan mark=" (vl-princ-to-string (cadr p))
                        " qty=" (nth 4 p)
                        " lh=[" (nth 5 p) "] rh=[" (nth 6 p)
                        "] flag=" (nth 8 p))))
     (sch:chk (strcat "  plan total lh=" (itoa planlh)
                      " rh=" (itoa planrh)))))
  ;; ---- verdict ------------------------------------------------------
  (setq verdict
    (cond
      ((null doors) "NO DOORS harvested - selection/xref problem.")
      ((= nh 0)
       "HAND DROPS AT STAGE 1 (harvest): no door record carries LH/RH even though SCHHAND shows the probe works - suspect property-set *SWING*/*HAND* interference or walls not passed.")
      ((and (> nh 0) (= (+ agglh aggrh) 0))
       "HAND DROPS AT STAGE 2 (aggregate): records carry HAND but aggregated lh/rh are zero.")
      ((null dres)
       "STAGE 3: no door schedule found - hand never gets a table to land in.")
      ((and (> (+ agglh aggrh) 0) (= (+ planlh planrh) 0))
       "HAND DROPS AT STAGE 4 (merge): aggregates carry lh/rh but the planned rows are blank.")
      ((and (> (+ planlh planrh) 0) (null lhcol)
            (= *sch:handmode* "cols"))
       "STAGE 5 (apply): plan carries lh/rh but the chart has NO LH column yet - it would be inserted at apply; if cells stay blank the InsertColumns/SetText on the cross-drawing table is failing.")
      ((> (+ planlh planrh) 0)
       "PIPELINE OK to the plan stage - if chart cells are still blank after apply, the failure is the cross-drawing cell WRITE (see SCH-trace.txt from the real scan).")
      (t "UNCLASSIFIED - send this report back.")))
  (sch:chk (strcat "VERDICT: " verdict))
  (sch:chk "SCHCHECK DONE")
  (if doc (sch:catch 'vla-EndUndoMark (list doc)))
  (princ (strcat "\n[SCH] Check report: " *sch:chk-path*))
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHHAND - per-door swing-hand diagnostic. For every native
;;; AEC_DOOR in model space, run the probe method and log the result
;;; AND the reason it is blank (no wall / no swing depth / etc.), so we
;;; can see why a given drawing's doors do or don't get LH/RH. Writes
;;; SCH-hand-report.txt beside the drawing. Read-only.
;;; ------------------------------------------------------------------

;; Read-only for the charts; the probe creates/deletes one temp line
;; per door, so the whole run is bracketed in an undo mark.
(defun c:SCHHAND ( / ss i n v walls hand path fh note stage dpth wr doc)
  (princ (strcat "\n[SCH v" *sch:version* "] hand diagnostic"))
  (setq doc (sch:catch 'vla-get-ActiveDocument
                       (list (vlax-get-acad-object))))
  (if doc (sch:catch 'vla-StartUndoMark (list doc)))
  (setq path (strcat (getvar "DWGPREFIX") "SCH-hand-report.txt"))
  (setq fh (open path "w"))
  (if fh
    (progn
      (write-line (strcat "SCHHAND v" *sch:version* "  dwg=" (getvar "DWGNAME")) fh)
      (close fh)))
  (setq walls (sch:collect-walls))
  (setq ss (ssget "_X" '((0 . "AEC_DOOR") (410 . "Model"))))
  (setq fh (open path "a"))
  (if fh
    (progn
      (write-line (strcat "native-walls=" (itoa (length walls))
                          "  native-doors=" (itoa (if ss (sslength ss) 0))) fh)
      (close fh)))
  (if ss
    (progn
      (setq i 0 n (sslength ss))
      (while (< i n)
        (if (= (rem i 25) 0) (princ "."))
        (setq v (sch:vla (ssname ss i)))
        (if v
          (progn
            (setq hand (sch:door-hand-probe v walls))
            (setq note (cdr (assoc "note" *sch:probe-last*))
                  stage (cdr (assoc "stage" *sch:probe-last*))
                  dpth (cdr (assoc "dpth" *sch:probe-last*)))
            (setq wr (sch:nearest-wall (sch:bbox-center v) walls 30.0))
            (setq fh (open path "a"))
            (if fh
              (progn
                (write-line
                  (strcat "door " (vla-get-Handle v)
                          "  hand=" (if hand hand "nil")
                          "  note=" (if note note "-")
                          "  stage=" (if stage stage "-")
                          "  dpth=" (if dpth (rtos dpth 2 2) "-")
                          "  nearwall=" (if wr "yes" "NO")
                          "  wallW=" (if wr (rtos (caddr wr) 2 2) "-")
                          "  style=" (sch:val->str (sch:prop v 'StyleName)))
                  fh)
                (close fh)))))
        (setq i (1+ i)))))
  (setq fh (open path "a"))
  (if fh (progn (write-line "SCHHAND DONE" fh) (close fh)))
  (if doc (sch:catch 'vla-EndUndoMark (list doc)))
  (princ (strcat "\n[SCH] Hand report written: " path))
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHTAGS - callout/tag census (READ-ONLY). Answers exactly what an
;;; automatic tag PLACER needs to know before it can be written:
;;;   1. which TK_ tag block definitions this drawing carries
;;;   2. how placed tags sit relative to their host opening - layer,
;;;      size, and offset - so new tags can match the office standard
;;;   3. which openings have NO callout yet (today's manual work)
;;; Writes SCH-tag-report.txt beside the drawing. Places nothing.
;;; ------------------------------------------------------------------

(defun sch:tagout (msg / fh)
  (if *sch:tag-path*
    (progn
      (setq fh (open *sch:tag-path* "a"))
      (if fh (progn (write-line msg fh) (close fh)))))
  (princ))

;; Wall frame for an opening: turns the host wall into a local
;; coordinate system so a tag's position can be expressed as SIGNED
;; along-wall / perpendicular offsets instead of a bare distance.
;; (sch:door-hand-probe builds the same frame inline for swing
;; detection; kept separate here so the verified swing path is not
;; disturbed - merge the two once the tag placer ships.)
;;   CTR   opening center            WDIR  unit vector along the wall
;;   WNORM unit perpendicular        WALLW host wall width
;;   DPTH  signed depth of the opening bbox off the wall centerline;
;;         for a swinging door its SIGN is the swing side
(defun sch:open-frame (vlaObj walls / bb c wrec wp1 wp2 wdir wnorm
                        perpv dpth pt)
  (setq bb (sch:bbox vlaObj))
  (setq c (if bb (list (/ (+ (car (car bb)) (car (cadr bb))) 2.0)
                       (/ (+ (cadr (car bb)) (cadr (cadr bb))) 2.0))))
  (setq wrec (if c (sch:nearest-wall c walls 30.0)))
  (if wrec
    (progn
      (setq wp1 (car wrec) wp2 (cadr wrec)
            wdir (sch:vunit (sch:v- wp2 wp1))
            wnorm (sch:vperp wdir)
            dpth 0.0)
      (foreach pt (list (sch:pt2 (car bb))
                        (list (car (car bb)) (cadr (cadr bb)))
                        (list (car (cadr bb)) (cadr (car bb)))
                        (sch:pt2 (cadr bb)))
        (setq perpv (sch:vdot (sch:v- pt wp1) wnorm))
        (if (> (abs perpv) (abs dpth)) (setq dpth perpv)))
      (if (> (sch:vlen wdir) 1e-9)
        (list (cons "CTR" c) (cons "WDIR" wdir) (cons "WNORM" wnorm)
              (cons "DPTH" dpth) (cons "WALLW" (caddr wrec)))))))

(defun c:SCHTAGS ( / fh ss i e d nm typ obj bb c w h lay tags hosts a
                    hist bestd best dx dy dd tagged untagged cnt defs
                    det nb nt k host walls fr wdir wnorm dpth bub txt
                    bd td sgn sb st wallH orient aligned kind
                    nsame nopp nswing naway nalign ncross doc)
  (princ (strcat "\n[SCH v" *sch:version* "] tag/callout census"))
  (setq *sch:tag-path* (strcat (getvar "DWGPREFIX") "SCH-tag-report.txt"))
  (setq fh (open *sch:tag-path* "w"))
  (if fh
    (progn
      (write-line (strcat "SCHTAGS v" *sch:version*
                          "  dwg=" (getvar "DWGNAME")) fh)
      (close fh)))
  ;; ---- 1. tag block definitions -------------------------------------
  (sch:tagout "== tag block definitions ==")
  (setq cnt 0 defs 0)
  (while (setq d (tblnext "BLOCK" (= cnt 0)))
    (setq cnt (1+ cnt) nm (cdr (assoc 2 d)))
    (if (and nm (wcmatch (strcase nm) "*TAG*"))
      (progn (setq defs (1+ defs)) (sch:tagout (strcat "   " nm)))))
  (sch:tagout (strcat "   (" (itoa defs) " tag-like of " (itoa cnt)
                      " block definitions)"))
  ;; ---- 2. placed tag entities ---------------------------------------
  (sch:tagout "== placed tags ==")
  (setq tags nil)
  (setq ss (ssget "_X" '((0 . "AEC_MVBLOCK_REF,INSERT") (410 . "Model"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq e (ssname ss i) d (entget e)
              typ (cdr (assoc 0 d)) nm (cdr (assoc 2 d)))
        (if (or (= typ "AEC_MVBLOCK_REF")
                (and nm (wcmatch (strcase nm) "TK_*TAG*")))
          (progn
            (setq obj (sch:vla e))
            (setq bb (if obj (sch:bbox obj)))
            (if bb
              (progn
                (setq c (list (/ (+ (car (car bb)) (car (cadr bb))) 2.0)
                              (/ (+ (cadr (car bb)) (cadr (cadr bb))) 2.0))
                      w (- (car (cadr bb)) (car (car bb)))
                      h (- (cadr (cadr bb)) (cadr (car bb)))
                      lay (sch:catch 'vlax-get-property (list obj "Layer")))
                (setq tags (cons (list c w h
                                       (if (eq (type lay) 'STR) lay "?")
                                       (if nm nm typ))
                                 tags))))))
        (setq i (1+ i)))))
  (sch:tagout (strcat "   total tag entities = " (itoa (length tags))))
  ;; layer histogram
  (setq hist nil)
  (foreach a tags
    (if (setq k (assoc (nth 3 a) hist))
      (setq hist (subst (cons (car k) (1+ (cdr k))) k hist))
      (setq hist (cons (cons (nth 3 a) 1) hist))))
  (foreach a hist
    (sch:tagout (strcat "   layer " (car a) " = " (itoa (cdr a)))))
  ;; bubble (square-ish) vs size-text (wide) split
  (setq nb 0 nt 0)
  (foreach a tags
    (if (and (> (nth 2 a) 0.001)
             (< (abs (- (/ (nth 1 a) (nth 2 a)) 1.0)) 0.25))
      (setq nb (1+ nb))
      (setq nt (1+ nt))))
  (sch:tagout (strcat "   bubble-shaped=" (itoa nb)
                      "  text-shaped=" (itoa nt)))
  ;; ---- 3. openings, and whether each already carries a tag ----------
  (sch:tagout "== openings vs tags ==")
  (setq hosts nil)
  (foreach k '(("AEC_DOOR" . "DOOR") ("AEC_WINDOW" . "WINDOW")
               ("AEC_WINDOW_ASSEMBLY" . "WINDOW"))
    (setq ss (ssget "_X" (list (cons 0 (car k)) (cons 410 "Model"))))
    (if ss
      (progn
        (setq i 0)
        (while (< i (sslength ss))
          (setq obj (sch:vla (ssname ss i)))
          (setq bb (if obj (sch:bbox obj)))
          (if bb
            (setq hosts
              (cons (list (list (/ (+ (car (car bb)) (car (cadr bb))) 2.0)
                                (/ (+ (cadr (car bb)) (cadr (cadr bb))) 2.0))
                          (cdr k) obj)
                    hosts)))
          (setq i (1+ i))))))
  (sch:tagout (strcat "   openings = " (itoa (length hosts))))
  (setq tagged 0 untagged 0 det 0)
  (foreach host hosts
    (setq c (car host) bestd nil best nil)
    (foreach a tags
      (setq dx (- (car (car a)) (car c))
            dy (- (cadr (car a)) (cadr c))
            dd (+ (* dx dx) (* dy dy)))
      (if (or (null bestd) (< dd bestd)) (setq bestd dd best a)))
    (setq bestd (if bestd (sqrt bestd) 1.0e12))
    (cond
      ((< bestd *sch:tagnear*)
       (setq tagged (1+ tagged))
       (if (< det 25)
         (progn
           (setq det (1+ det))
           (sch:tagout (strcat "   " (cadr host) " TAGGED d="
                               (rtos bestd 2 1)
                               " lay=" (nth 3 best)
                               " size=" (rtos (nth 1 best) 2 1) "x"
                               (rtos (nth 2 best) 2 1))))))
      (t
       (setq untagged (1+ untagged))
       (if (< det 25)
         (progn
           (setq det (1+ det))
           (sch:tagout (strcat "   " (cadr host) " UNTAGGED nearest="
                               (rtos bestd 2 1))))))))
  (sch:tagout (strcat "   tagged=" (itoa tagged)
                      "  untagged=" (itoa untagged)
                      "  (within " (rtos *sch:tagnear* 2 0) "in)"))
  ;; ---- 4. SIGNED offsets in each host's own wall frame -------------
  ;; This is the part a placer needs. A bare distance cannot say WHICH
  ;; SIDE a tag sits on. Expressing every tag in its host wall's frame
  ;; settles three questions that are otherwise guesswork:
  ;;   * do door callouts sit on the SWING side or the opposite side?
  ;;   * are a window's bubble and size text on the SAME side of the
  ;;     wall, or split across it?
  ;;   * does the size text rotate to follow the wall?
  ;; perp is reported so that POSITIVE = the swing side for doors.
  (sch:tagout "== signed offsets (tag position in the host wall frame) ==")
  (setq walls (sch:collect-walls))
  (sch:tagout (strcat "   walls=" (itoa (length walls))))
  (setq det 0 nsame 0 nopp 0 nswing 0 naway 0 nalign 0 ncross 0)
  (foreach host hosts
    (setq c (car host) kind (cadr host) obj (caddr host))
    (setq fr (if obj (sch:open-frame obj walls)))
    (if fr
      (progn
        (setq wdir (cdr (assoc "WDIR" fr))
              wnorm (cdr (assoc "WNORM" fr))
              dpth (cdr (assoc "DPTH" fr)))
        ;; nearest bubble and nearest size-text to this opening
        (setq bub nil txt nil bd nil td nil)
        (foreach a tags
          (setq dx (- (car (car a)) (car c))
                dy (- (cadr (car a)) (cadr c))
                dd (+ (* dx dx) (* dy dy)))
          (if (< dd (* *sch:tagnear* *sch:tagnear*))
            (if (and (> (nth 2 a) 0.001)
                     (< (abs (- (/ (nth 1 a) (nth 2 a)) 1.0)) 0.25))
              (if (or (null bd) (< dd bd)) (setq bd dd bub a))
              (if (or (null td) (< dd td)) (setq td dd txt a)))))
        ;; signed decomposition, flipped so +perp = swing side
        (setq sgn (if (and dpth (< dpth 0.0)) -1.0 1.0))
        (setq sb (if bub
                   (list (sch:vdot (sch:v- (car bub) c) wdir)
                         (* sgn (sch:vdot (sch:v- (car bub) c) wnorm)))))
        (setq st (if txt
                   (list (sch:vdot (sch:v- (car txt) c) wdir)
                         (* sgn (sch:vdot (sch:v- (car txt) c) wnorm)))))
        ;; wall orientation vs the size-text tag's own aspect
        (setq wallH (> (abs (car wdir)) (abs (cadr wdir))))
        (setq orient (if txt (if (> (nth 1 txt) (nth 2 txt)) "H" "V") "-"))
        (setq aligned (if txt
                        (if (or (and wallH (= orient "H"))
                                (and (not wallH) (= orient "V")))
                          "Y" "N")
                        "-"))
        (if (and txt (= aligned "Y")) (setq nalign (1+ nalign)))
        (if (and sb (> (cadr sb) 0.0)) (setq nswing (1+ nswing)))
        (if (and sb (<= (cadr sb) 0.0)) (setq naway (1+ naway)))
        (if (and sb st)
          (if (or (and (> (cadr sb) 0.0) (> (cadr st) 0.0))
                  (and (<= (cadr sb) 0.0) (<= (cadr st) 0.0)))
            (setq nsame (1+ nsame))
            (setq nopp (1+ nopp))))
        (if (< det 40)
          (progn
            (setq det (1+ det))
            (sch:tagout
              (strcat "   " kind
                      " swing=" (if dpth (rtos dpth 2 1) "-")
                      " wall=" (if wallH "H" "V")
                      "  bub[along=" (if sb (rtos (car sb) 2 1) "-")
                      " perp=" (if sb (rtos (cadr sb) 2 1) "-")
                      "]  txt[along=" (if st (rtos (car st) 2 1) "-")
                      " perp=" (if st (rtos (cadr st) 2 1) "-")
                      "] txtorient=" orient " aligned=" aligned))))))
    )
  (sch:tagout (strcat "   SUMMARY bubble-on-swing-side=" (itoa nswing)
                      "  bubble-away=" (itoa naway)))
  (sch:tagout (strcat "   SUMMARY bubble+text SAME side=" (itoa nsame)
                      "  OPPOSITE sides=" (itoa nopp)))
  (sch:tagout (strcat "   SUMMARY size-text wall-aligned=" (itoa nalign)))
  (sch:tagout "SCHTAGS DONE")
  (princ (strcat "\n[SCH] Tag report: " *sch:tag-path*))
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHTAGINSTALL / c:SCHTAGUNINSTALL - set up the callout add-in so
;;; AutoCAD loads it AUTOMATICALLY at start-up on a drafter's machine.
;;;
;;; The add-in ships as an AutoCAD "Autoloader bundle" - a folder that
;;; AutoCAD scans on start-up. Copying it into the user's
;;; ApplicationPlugins folder IS the whole install: no admin rights, no
;;; NETLOAD to remember, no registry editing, and nothing to re-do after
;;; an AutoCAD patch. The commands only appear on AutoCAD; BricsCAD
;;; cannot host a .NET add-in and simply will not see them.
;;;
;;; Source is a SchTagNet.bundle folder sitting beside SCH.lsp, so the
;;; whole tool travels as one directory.
;;; ------------------------------------------------------------------

(defun sch:slash (p) (vl-string-translate "\\" "/" p))

;; create every missing level of a path (vl-mkdir does one at a time)
(defun sch:mkpath (path / parts cur)
  (setq parts (sch:split (sch:slash path) "/") cur nil)
  (foreach p parts
    (setq cur (if cur (strcat cur "/" p) p))
    (if (and (/= cur "") (not (vl-file-directory-p cur)))
      (vl-mkdir cur)))
  (vl-file-directory-p (sch:slash path)))

(defun sch:split (s sep / out i c cur)
  (setq cur "" out nil i 1)
  (while (<= i (strlen s))
    (setq c (substr s i 1))
    (if (= c sep)
      (progn (setq out (cons cur out)) (setq cur ""))
      (setq cur (strcat cur c)))
    (setq i (1+ i)))
  (reverse (cons cur out)))

(defun sch:tagbundle-src ( / self)
  (if (setq self (sch:selfpath))
    (strcat (vl-filename-directory (sch:slash self)) "/SchTagNet.bundle")))

(defun sch:tagbundle-dst ( / app)
  (if (setq app (getenv "APPDATA"))
    (strcat (sch:slash app)
            "/Autodesk/ApplicationPlugins/SchTagNet.bundle")))

(defun c:SCHTAGINSTALL ( / src dst ok bad pair from to)
  (princ (strcat "\n[SCH v" *sch:version* "] installing the callout add-in"))
  (setq src (sch:tagbundle-src)
        dst (sch:tagbundle-dst))
  (cond
    ((null src)
     (princ "\n[SCH] Cannot locate SCH.lsp, so cannot find the add-in beside it."))
    ((null dst)
     (princ "\n[SCH] APPDATA is not set - cannot locate the AutoCAD plug-ins folder."))
    ((null (findfile (strcat src "/PackageContents.xml")))
     (princ (strcat "\n[SCH] Add-in not found at " src
                    "\n[SCH] Copy the SchTagNet.bundle folder next to SCH.lsp, then rerun.")))
    ((null (sch:mkpath (strcat dst "/Contents")))
     (princ (strcat "\n[SCH] Could not create " dst)))
    (t
     (setq ok 0 bad nil)
     (foreach pair
       (list (cons "/PackageContents.xml"        "/PackageContents.xml")
             (cons "/Contents/SchTagNet.dll"     "/Contents/SchTagNet.dll")
             (cons "/Contents/SchTagNet.deps.json"
                   "/Contents/SchTagNet.deps.json")
             (cons "/Contents/SchTagNet.runtimeconfig.json"
                   "/Contents/SchTagNet.runtimeconfig.json"))
       (setq from (strcat src (car pair))
             to   (strcat dst (cdr pair)))
       (if (findfile from)
         (progn
           (sch:catch 'vl-file-delete (list to))
           (if (sch:catch 'vl-file-copy (list from to))
             (setq ok (1+ ok))
             (setq bad (cons (cdr pair) bad))))))
     (cond
       (bad
        (princ (strcat "\n[SCH] Copied " (itoa ok)
                       " file(s) but FAILED on: "
                       (apply 'strcat (mapcar '(lambda (x) (strcat x " ")) bad))))
        (princ "\n[SCH] Usually means AutoCAD already has the add-in loaded - close ALL AutoCAD windows and rerun."))
       (t
        (princ (strcat "\n[SCH] Installed " (itoa ok) " file(s) to:\n         " dst))
        (princ "\n[SCH] RESTART AutoCAD - the add-in loads itself from then on.")
        (princ "\n[SCH] Then: SCHTAGDRY to preview, SCHTAG to place, SCHTAGVIEW to switch sets.")))))
  (princ))

(defun c:SCHTAGUNINSTALL ( / dst n f)
  (princ (strcat "\n[SCH v" *sch:version* "] removing the callout add-in"))
  (setq dst (sch:tagbundle-dst))
  (if (null dst)
    (princ "\n[SCH] APPDATA is not set - nothing to do.")
    (progn
      (setq n 0)
      (foreach f (list "/Contents/SchTagNet.dll"
                       "/Contents/SchTagNet.deps.json"
                       "/Contents/SchTagNet.runtimeconfig.json"
                       "/PackageContents.xml")
        (if (findfile (strcat dst f))
          (if (sch:catch 'vl-file-delete (list (strcat dst f)))
            (setq n (1+ n)))))
      (sch:catch 'vl-rmdir (list (strcat dst "/Contents")))
      (sch:catch 'vl-rmdir (list dst))
      (if (> n 0)
        (progn
          (princ (strcat "\n[SCH] Removed " (itoa n) " file(s) from " dst))
          (princ "\n[SCH] Restart AutoCAD to finish unloading."))
        (princ "\n[SCH] Add-in was not installed (nothing removed)."))))
  (princ))

;;; ------------------------------------------------------------------
;;; Auto-load install + GitHub updates
;;; ------------------------------------------------------------------

;; where this file lives (support path first, then the default home)
(defun sch:selfpath ( / p)
  (cond ((setq p (findfile "SCH.lsp")) (sch:slash p))
        ((setq p (findfile *sch:home*)) (sch:slash p))))

(defun sch:file-contains (path pat / f line found)
  (if (and path (setq f (open path "r")))
    (progn
      (while (and (not found) (setq line (read-line f)))
        (if (wcmatch line (strcat "*" pat "*")) (setq found T)))
      (close f)))
  found)

;; Auto-load is OPT-IN. SCH.lsp does NOT touch acaddoc.lsp at load
;; time - that write is what could turn a single bad load into a
;; crash on every drawing open. The user runs SCHINSTALL once;
;; SCHUNINSTALL removes it. Both RECONCILE: they strip any existing/
;; duplicate/stale SCH-AUTOLOAD lines first, and install then writes
;; ONE canonical, path-independent loader - so a moved file or an old
;; absolute-path entry is repaired, never left broken or duplicated.

;; the acaddoc.lsp already on the support search path, or nil. Both
;; install and uninstall resolve the target through this one helper so
;; they always act on the SAME file.
(defun sch:acaddoc-find () (findfile "acaddoc.lsp"))

;; acaddoc.lsp path: the one on the support path, else a fresh copy
;; under the roamable Support folder. nil only if none can be made.
(defun sch:acaddoc-target ( / tgt dir)
  (setq tgt (sch:acaddoc-find))
  (if (null tgt)
    (progn
      (setq dir (strcat (getvar "ROAMABLEROOTPREFIX") "Support"))
      (vl-mkdir dir)
      (setq tgt (strcat dir "\\acaddoc.lsp"))))
  tgt)

;; read every line of path top-to-bottom (nil if it can't be opened)
(defun sch:read-lines (path / f line lines)
  (if (and path (setq f (open path "r")))
    (progn
      (while (setq line (read-line f)) (setq lines (cons line lines)))
      (close f)))
  (reverse lines))

;; drop every SCH-AUTOLOAD marker AND the load line right after it -
;; collapses duplicates and stale copies. Returns the kept lines.
(defun sch:acaddoc-strip (lines / out skipnext)
  (setq out nil skipnext nil)
  (foreach line lines
    (cond
      (skipnext (setq skipnext nil))
      ((wcmatch line "*SCH-AUTOLOAD*") (setq skipnext T))
      (t (setq out (cons line out)))))
  (reverse out))

;; install (or repair) the auto-load entry. Reconciles to exactly one
;; canonical loader: bare-name + findfile guard, so it resolves SCH.lsp
;; on the AutoCAD support search path and never goes stale when the
;; file moves. The nil load arg keeps a missing file fail-soft.
(defun c:SCHINSTALL ( / tgt lines f)
  (princ (strcat "\n[SCH v" *sch:version* "]"))
  (cond
    ((null (sch:selfpath))
     (princ (strcat "\n[SCH] Cannot install: SCH.lsp is not on the support search path"
                    " (*sch:home* = " *sch:home*
                    "). Put SCH.lsp in a support folder, or edit *sch:home*, then rerun SCHINSTALL.")))
    ((null (setq tgt (sch:acaddoc-target)))
     (princ "\n[SCH] Cannot install: no writable acaddoc.lsp / Support folder found."))
    (t
     (setq lines (sch:acaddoc-strip (sch:read-lines tgt)))
     ;; drop trailing blanks so repeated installs never accumulate them
     (while (and lines (= "" (last lines)))
       (setq lines (reverse (cdr (reverse lines)))))
     (setq f (open tgt "w"))
     (cond
       (f
        (foreach line lines (write-line line f))
        (write-line "" f)
        (write-line ";; SCH-AUTOLOAD (added by SCH.lsp; remove with SCHUNINSTALL)" f)
        (write-line "(if (findfile \"SCH.lsp\") (load \"SCH.lsp\" nil))" f)
        (close f)
        (princ (strcat "\n[SCH] Auto-load installed (" (sch:slash tgt)
                       "). SCH now loads in every drawing. SCHUNINSTALL removes it.")))
       (t
        (princ "\n[SCH] Install failed - acaddoc.lsp is write-protected or in use.")))))
  (princ))

(defun c:SCHUNINSTALL ( / tgt lines f)
  (princ (strcat "\n[SCH v" *sch:version* "]"))
  (setq tgt (sch:acaddoc-find))
  (cond
    ((and tgt (sch:file-contains tgt "SCH-AUTOLOAD"))
     (setq lines (sch:acaddoc-strip (sch:read-lines tgt)))
     (setq f (open tgt "w"))
     (if f
       (progn
         (foreach line lines (write-line line f))
         (close f)
         (princ (strcat "\n[SCH] Auto-load removed from " (sch:slash tgt))))
       (princ "\n[SCH] Could not rewrite acaddoc.lsp - write-protected or in use.")))
    (t (princ "\n[SCH] No auto-load entry found.")))
  (princ))

(defun sch:http-get (url / req status body)
  (setq req (sch:catch 'vlax-create-object
              (list "WinHttp.WinHttpRequest.5.1")))
  (if (null req)
    (setq req (sch:catch 'vlax-create-object (list "MSXML2.XMLHTTP"))))
  (if req
    (progn
      (sch:catch 'vlax-invoke-method (list req 'Open "GET" url
                                           :vlax-false))
      (sch:catch 'vlax-invoke-method (list req 'Send))
      (setq status (sch:catch 'vlax-get-property (list req 'Status)))
      (if (and status (= status 200))
        (setq body (sch:catch 'vlax-get-property (list req
                                                       'ResponseText))))
      (sch:catch 'vlax-release-object (list req))))
  body)

;; pull the latest SCH.lsp (and SCHTEST.lsp when present) from GitHub,
;; back up the old file, overwrite, reload.
(defun c:SCHUPDATE ( / self body bak f tst body2)
  (princ (strcat "\n[SCH] v" *sch:version*
                 " - checking GitHub for updates..."))
  (setq self (sch:selfpath))
  (cond
    ((null self)
     (princ "\n[SCH] Cannot locate the local SCH.lsp - set *sch:home* at the top of the file."))
    (t
     (setq body (sch:http-get (strcat *sch:raw-base* "SCH.lsp")))
     (cond
       ((or (null body) (< (strlen body) 1000)
            (null (vl-string-search "(defun c:SCH " body)))
        (princ "\n[SCH] Update failed - could not fetch a valid SCH.lsp from GitHub (check internet access)."))
       (t
        (setq bak (strcat self ".bak"))
        (sch:catch 'vl-file-delete (list bak))
        (sch:catch 'vl-file-copy (list self bak))
        (setq f (open self "w"))
        (if f
          (progn
            (princ body f)
            (close f)
            ;; refresh SCHTEST.lsp too when it sits beside SCH.lsp
            (setq tst (strcat (vl-filename-directory self)
                              "/SCHTEST.lsp"))
            (if (findfile tst)
              (progn
                (setq body2 (sch:http-get (strcat *sch:raw-base*
                                                  "SCHTEST.lsp")))
                (if (and body2 (> (strlen body2) 500))
                  (progn
                    (setq f (open tst "w"))
                    (if f (progn (princ body2 f) (close f)))))))
            (princ (strcat "\n[SCH] Updated from GitHub (backup: "
                           bak "). Reloading..."))
            ;; reload is the LAST action, guarded: redefining the
            ;; function that is still executing is safe in BricsCAD but
            ;; AutoCAD's engine is touchier about it
            (if (vl-catch-all-error-p
                  (vl-catch-all-apply 'load (list self)))
              (princ "\n[SCH] Update saved but auto-reload failed - restart CAD (or APPLOAD SCH.lsp) to finish.")
              (princ "\n[SCH] Done.")))
          (princ "\n[SCH] Update failed - SCH.lsp is write-protected or in use."))))))
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHSAFE - run SCH with both crash-prone subsystems disabled
;;; ------------------------------------------------------------------

;; Use this if plain SCH takes CAD down. Turns off the AecX COM bridge
;; AND the AEC explode, then runs SCH normally. Marks/sizes then come
;; from measured geometry snapped to the DSLD catalog and LH/RH from
;; the probe method - exactly the path BricsCAD already uses, so the
;; results are the ones we regression-tested there.
;; If SCH aborts mid-run the gates deliberately STAY off for the rest
;; of the session (a safe failure); reload SCH.lsp to reset them.
(defun c:SCHSAFE ( / a e)
  (princ (strcat "\n[SCH v" *sch:version*
                 "] SAFE MODE - AecX COM and AEC explode disabled"))
  (setq a *sch:use-aecx* e *sch:use-explode*)
  (setq *sch:use-aecx* nil *sch:use-explode* nil)
  (c:SCH)
  (setq *sch:use-aecx* a *sch:use-explode* e)
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHHELP - quick reference pop-up
;;; ------------------------------------------------------------------

(defun c:SCHHELP ()
  (alert (strcat
    "SCH - DSLD Schedule of Openings auto-fill\n"
    "------------------------------------------------\n"
    "SCH  Scan a plan area, fill or create the WINDOW and\n"
    "     DOOR schedules.\n"
    "  1. Pick two corners around ONE house. Xrefs inside the\n"
    "     box are included - interior + exterior in one scan.\n"
    "     Type All (or run from a paper-space layout) to scan\n"
    "     the entire model space instead.\n"
    "  2. SCH manages its OWN charts (on the SCH layer) - in\n"
    "     THIS drawing first, then in any other OPEN drawing\n"
    "     (so a scan in the Exterior construct updates charts\n"
    "     living in the Interior construct - keep both open).\n"
    "     Legacy hand-made charts are ignored and untouched;\n"
    "     if none of SCH's charts exist, pick a point and it\n"
    "     creates them in DSLD format. To hand an old chart\n"
    "     over to SCH, move it onto the SCH layer.\n"
    "  3. Preview before anything is written:\n"
    "       + new row   ~ changed   = unchanged   ! kept\n"
    "     LH/RH placement: columns after QTY, or in the\n"
    "     description.\n"
    "     Counts: 'Replace with this scan' for re-scans of the\n"
    "     same area; 'Add to existing' when scanning ANOTHER\n"
    "     area (e.g. interior first, exterior later - counts\n"
    "     accumulate on the same charts).\n"
    "\n"
    "LH/RH: stand on the side the door opens AWAY from;\n"
    "hinge on your left = LH. Doubles, sliders and garage\n"
    "doors are counted as 'swing unknown'.\n"
    "Cased openings get the 4\"/6\" host-wall size in their\n"
    "description. Sizes measured from geometry are snapped to\n"
    "DSLD standards and marked 'verify' in the notes.\n"
    "\n"
    "SCHSAFE - run SCH with the two crash-prone subsystems\n"
    "     (AecX COM + AEC explode) turned OFF. Use this if SCH\n"
    "     takes CAD down. Sizes then come from geometry and\n"
    "     LH/RH from the probe method.\n"
    "SCHDIAG - diagnostics report (read-only, safe anywhere)\n"
    "SCHCHECK - trace the whole fill pipeline, find where data\n"
    "     is lost (read-only, writes SCH-check-report.txt)\n"
    "SCHHAND - per-door swing report + why a door has no LH/RH\n"
    "SCHTAGS - callout/tag census: which openings already have\n"
    "     tags and which are still untagged (read-only)\n"
    "SCHTRACE - toggle the crash breadcrumb log (SCH-trace.txt\n"
    "     beside the drawing; last line names what killed CAD)\n"
    "SCHINSTALL - load SCH automatically in every drawing\n"
    "SCHUPDATE - pull the latest version from GitHub\n"
    "SCHUNINSTALL - remove the automatic loading\n"
    "SCHHELP - this help\n"
    "\n"
    "Auto-load is opt-in: run SCHINSTALL once and SCH loads in\n"
    "every drawing thereafter (via acaddoc.lsp); SCHUNINSTALL\n"
    "removes it. Wording and calibration live at the top of\n"
    "SCH.lsp: description map, size catalogs, trim allowances,\n"
    "and the LH/RH convention."))
  (princ))

;;; ------------------------------------------------------------------

(princ (strcat "\n[SCH] v" *sch:version*
               " loaded. Commands: SCH, SCHSAFE, SCHDIAG, SCHHELP, SCHUPDATE, SCHINSTALL."))
;; OPT-IN auto-load: we deliberately do NO file I/O at load time. The
;; old build wrote acaddoc.lsp here, which could turn one failed load
;; into a crash on every drawing open. Run SCHINSTALL once to enable.
(princ "\n[SCH] Auto-load is opt-in - run SCHINSTALL once to load SCH in every drawing (SCHUNINSTALL to disable).")
(princ)
