;;;-----------------------------------------------------------------------;;;
;;; ADIM.LSP - DSLD Auto Wall Dimensioner
;;;
;;; Command:    ADIM  (Auto DIMension)
;;;
;;; Workflow:   1. Window a boundary box around the wall / plan area.
;;;             2. A HORIZONTAL follow line ghosts under the cursor -
;;;                every CLICK drops one where it sits (as many as you
;;;                need), SPACE switches to VERTICAL lines (Space again
;;;                toggles back), Enter/right-click finishes placing.
;;;             3. Each follow line picks up ONE STUD POINT PER WALL it
;;;                crosses - the wall's justified stud face (the DSLD
;;;                production pattern: no wall-thickness segments in
;;;                the chains).  On plain linework, crossing clusters
;;;                resolve to the stud faces first (stud-width pair
;;;                wins, rock-only pairs are inset by the sheetrock
;;;                thickness) and the lower face is kept.
;;;             4. A chain dim string lands ON each follow line
;;;                (left-to-right / rear-to-front), plus an overall
;;;                offset toward the nearer box edge, on A-Anno-Dims
;;;                in the Annotative dimstyle (DSLD standard).
;;;             5. Pick any dims to DISCARD (only ADIM's own dims are
;;;                touched), Enter keeps all.  One U undoes the run.
;;;
;;; Commands:   ADIM        - main routine
;;;             ADIMROOM    - click inside a room -> one dim across it
;;;                           (Space toggles horizontal/vertical)
;;;             ADIMLAYERS  - pick samples to set the layer filter
;;;             ADIMDIAG    - crossing census -> ADIMDIAG-report.txt
;;;                           (run on a production DWG in ACA/BricsCAD
;;;                           and send the report back, same drill as
;;;                           SCHDIAG - the ODA DXFs on this machine
;;;                           dropped every AEC wall, so the stud-face
;;;                           logic must be validated live)
;;;             ADIMHELP    - quick reference
;;;
;;; Compatibility: AutoCAD Architecture (the company platform - where
;;;                production testing happens) + BricsCAD V26 (backup
;;;                platform; also the local headless test harness since
;;;                this dev machine has no ACA seat).  Pure AutoLISP /
;;;                VL-LISP via vl-load-com.  Model space.
;;;-----------------------------------------------------------------------;;;

(vl-load-com)

;;-- User-tunable defaults (edit here) ----------------------------------;;

(setq *DSLD-ADIM-VERSION* "1.5.0")

;; STRICT include list (RPR precedent): only linework whose layer
;; matches one of these wildcard patterns is dimensioned.  DSLD walls
;; live on A-Wall / A-Wall-Intr (xref-prefixed variants match too).
;; nil = any layer not on the ignore list.  ADIMLAYERS rebuilds this
;; from picked sample entities.
(setq *DSLD-ADIM-LAYERS*        '("*A-WALL*"))

;; Never dimension to these - finish, footing, annotation noise.
;; A-Wall-Ftng and A-Wall-Patt match the include list above, so they
;; MUST stay ignored here or footing/poche lines get dims.
(setq *DSLD-ADIM-IGNORE-LAYERS*
  '("*PATT*" "*FTNG*" "*ANNO*" "*IDEN*" "*GYP*" "*ROCK*" "*GWB*"
    "*DRYWALL*" "*SHEET*" "DEFPOINTS" "*NPLT*" "*SCRN*" "*TTLB*"
    "*GLAZ*" "*DOOR*" "*SSS"))

;; Pull crossings out of block/xref inserts too?  Off by default -
;; nested linework can't be layer-filtered, so everything inside the
;; insert that crosses the follow line becomes a candidate (the
;; stud-pair logic still filters clusters).  Set T when the walls
;; live in an xref.
(setq *DSLD-ADIM-INCLUDE-INSERTS* nil)

;; Stud-face resolution.  DSLD wall styles are TK_Stud-3.5 / TK_Stud-5.5
;; (per the SCH discovery report), so inside each crossing cluster every
;; pair separated by a stud width IS a set of stud faces (multiple pairs
;; per cluster survive - double walls / chases); brick veneer, sheathing
;; and gyp lines get dropped.  A cluster with no stud pair whose outer
;; faces sit at stud + 2x rock means the drawing shows the rock faces
;; only - both crossings are inset by *DSLD-ADIM-GYP* to land on the
;; stud.
;; TOL is deliberately TIGHT (1/16"): ACA wall geometry is exact, and a
;; loose tolerance would let a 3.625" brick wythe pass as a 3.5" stud.
;; GAP must exceed stud + 2x rock (6.5") or a bare rock-to-rock pair
;; splits into two clusters and the inset rule can never fire (bug
;; found by ADIMTEST v1.0.0 against the Timsbury exterior).
(setq *DSLD-ADIM-STUD-WIDTHS*   '(3.5 5.5))  ; inches
(setq *DSLD-ADIM-STUD-TOL*      0.0625)      ; pair-match tolerance
(setq *DSLD-ADIM-GYP*           0.5)         ; sheetrock thickness
(setq *DSLD-ADIM-CLUSTER-GAP*   7.0)         ; crossings closer than this
                                             ; belong to one wall assembly
;; Max finish-shell depth outside a stud face (rock / air, NOT brick).
;; Used by the AEC baseline-to-faces expansion: measured on Timsbury,
;; shells are 0" / 0.5" / 1.0" while the brick wythe side is 4.0" -
;; keeping this at 1.0 is what stops the stud landing on the brick
;; side of an exterior wall.
(setq *DSLD-ADIM-SHELL-MAX*     1.0)
(setq *DSLD-ADIM-FUZZ*          0.03125)     ; 1/32" duplicate merge

;; One stud point per wall (the DSLD production pattern - measured on
;; 2,308 Timsbury dims: zero wall-thickness chain segments, 62% of
;; wall-referencing origins land exactly on the wall's JUSTIFIED stud
;; face, which is the AEC baseline).  'one = one point per wall
;; (default); 'faces = both stud faces (panel-shop style).
(setq *DSLD-ADIM-WALL-POINT*    'one)

;; Dim placement: each string sits ON its follow line (the user slides
;; the line to where the dims belong - DSLD dims run along the plan,
;; not stacked outside it).  The overall dim goes this far beyond the
;; follow line, toward the nearer boundary-box edge (16" = the
;; strongest offset peak in the production dims).
(setq *DSLD-ADIM-OVERALL-OFF*   16.0)
(setq *DSLD-ADIM-OVERALL*       T)           ; draw the overall dim

;; ADIMROOM: how far (each way) the room probe reaches when finding the
;; walls that bracket the clicked point.  333' covers any plan.
(setq *DSLD-ADIM-ROOM-SPAN*     4000.0)

;; Scan wall objects inside attached XREFS too.  The DSLD constructs
;; overlay each other at identity (Interior xrefs Exterior and vice
;; versa - verified on Timsbury), so dims run in one construct can
;; reference the other's walls.  Only xrefs placed at 0,0 / rot 0 /
;; scale 1 are walked (mirrored or displaced xrefs are skipped).
(setq *DSLD-ADIM-XREF-WALLS*    T)

;; DSLD output standards (verified against production Constructs).
(setq *DSLD-ADIM-DIM-LAYER*     "A-Anno-Dims")
(setq *DSLD-ADIM-DIMSTYLE*      "Annotative") ; used if it exists, else current

;;-- Session state ------------------------------------------------------;;
(or *DSLD-ADIM-LAST-BBOX* (setq *DSLD-ADIM-LAST-BBOX* nil))
(setq *DSLD-ADIM-CLEANUP*    nil)  ; restore-state stash (shared *error*)
(setq *DSLD-ADIM-TEMPS*      nil)  ; temp entities (box, follow lines)
(setq *DSLD-ADIM-DIAG*       nil)  ; T while ADIMDIAG collects
(setq *DSLD-ADIM-DIAG-ROWS*  nil)  ; candidate log for the report
(setq *DSLD-ADIM-XREF-CACHE* nil)  ; per-command xref wall-bbox cache
(setq *DSLD-ADIM-XSEG-CACHE* nil)  ; per-command xref baseline-segment cache

;;-----------------------------------------------------------------------;;
;; Shared helpers (stash / cleanup / *error* - RPR pattern)
;;-----------------------------------------------------------------------;;

(defun dsld-adim-msg (s) (princ (strcat "\n[ADIM] " s)) (princ))

(defun dsld-adim-stash (key val)
  (setq *DSLD-ADIM-CLEANUP*
        (cons (cons key val)
              (vl-remove-if '(lambda (kv) (eq (car kv) key))
                            *DSLD-ADIM-CLEANUP*))))

(defun dsld-adim-set-dimstyle-by-name (name / doc)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (vla-put-ActiveDimStyle doc (vla-Item (vla-get-DimStyles doc) name)))

(defun dsld-adim-cleanup ( / kv)
  (foreach kv *DSLD-ADIM-CLEANUP*
    (vl-catch-all-apply
      '(lambda ()
         (cond
           ((eq (car kv) 'dimstyle)
            (dsld-adim-set-dimstyle-by-name (cdr kv)))
           ((eq (car kv) 'osmode)  (setvar "OSMODE"  (cdr kv)))
           ((eq (car kv) 'clayer)  (setvar "CLAYER"  (cdr kv)))
           ((eq (car kv) 'temps)
            (foreach te (cdr kv) (if (entget te) (entdel te))))
           ((eq (car kv) 'undo)    (command "_.UNDO" "_End"))
           ((eq (car kv) 'cmdecho) (setvar "CMDECHO" (cdr kv)))))))
  (setq *DSLD-ADIM-CLEANUP*    nil
        *DSLD-ADIM-TEMPS*      nil
        *DSLD-ADIM-DIAG*       nil
        *DSLD-ADIM-XREF-CACHE* nil
        *DSLD-ADIM-XSEG-CACHE* nil)
  (redraw))

;; Shared *error* body.  Commands bind:  (setq *error* dsld-adim-cmd-error)
;; with *error* in their local-variable list.
(defun dsld-adim-cmd-error (msg)
  (dsld-adim-cleanup)
  (if (and msg
           (not (member (strcase msg T)
                        '("function cancelled" "quit / exit abort"
                          "console break"))))
    (princ (strcat "\n[ADIM] Error: " msg)))
  (princ))

;; Temp entity: entmake + track for cleanup.  Returns the ename.
(defun dsld-adim-temp-ent (elist / e)
  (entmake elist)
  (setq e (entlast))
  (setq *DSLD-ADIM-TEMPS* (cons e *DSLD-ADIM-TEMPS*))
  (dsld-adim-stash 'temps *DSLD-ADIM-TEMPS*)
  e)

(defun dsld-adim-ensure-layer (name)
  (if (not (tblsearch "LAYER" name))
    (entmake (list '(0 . "LAYER")
                   '(100 . "AcDbSymbolTableRecord")
                   '(100 . "AcDbLayerTableRecord")
                   (cons 2 name) '(70 . 0) '(62 . 7) '(6 . "Continuous"))))
  name)

(defun dsld-adim-join (lst sep / s)
  (setq s (if lst (car lst) ""))
  (foreach x (cdr lst) (setq s (strcat s sep x)))
  s)

(defun dsld-adim-clamp (v lo hi) (min (max v lo) hi))

;;-----------------------------------------------------------------------;;
;; Layer filter
;;-----------------------------------------------------------------------;;

(defun dsld-adim-ignored-p (lay / up)
  (setq up (strcase lay))
  (vl-some '(lambda (p) (wcmatch up (strcase p))) *DSLD-ADIM-IGNORE-LAYERS*))

(defun dsld-adim-layok (lay / up)
  (setq up (strcase lay))
  (and (not (dsld-adim-ignored-p lay))
       (or (null *DSLD-ADIM-LAYERS*)
           (vl-some '(lambda (p) (wcmatch up (strcase p))) *DSLD-ADIM-LAYERS*))))

;;-----------------------------------------------------------------------;;
;; Follow-line drag (grread + XOR ghost line)
;;-----------------------------------------------------------------------;;

(defun dsld-adim-xor (c horiz xmin ymin xmax ymax)
  (if horiz
    (grdraw (list xmin c 0.0) (list xmax c 0.0) -1)
    (grdraw (list c ymin 0.0) (list c ymax 0.0) -1)))

;; Slide a line across the box; returns the picked Y (horiz) / X
;; (vertical) coordinate, or nil if the user skipped (Enter / Space /
;; Esc / right-click).
(defun dsld-adim-drag (xmin ymin xmax ymax horiz / gr code data cur res done)
  (prompt (if horiz
    "\n[ADIM] Slide the HORIZONTAL follow line across the wall - click to set, Enter to skip: "
    "\n[ADIM] Slide the VERTICAL follow line across the wall - click to set, Enter to skip: "))
  (setq done nil res nil cur nil)
  (while (not done)
    (setq gr (grread T 15 0) code (car gr) data (cadr gr))
    (cond
      ((= code 5)                          ; cursor moved
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq cur (if horiz
                   (dsld-adim-clamp (cadr data) ymin ymax)
                   (dsld-adim-clamp (car data) xmin xmax)))
       (dsld-adim-xor cur horiz xmin ymin xmax ymax))
      ((= code 3)                          ; click = set
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq res (if horiz
                   (dsld-adim-clamp (cadr data) ymin ymax)
                   (dsld-adim-clamp (car data) xmin xmax))
             done T))
      ((and (= code 2) (member data '(13 32 27)))  ; Enter/Space/Esc = skip
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq done T))
      ((member code '(11 25))              ; right-click = skip
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq done T))
      (T nil)))
  res)

;; Multi-line placement: every CLICK drops a follow line at the cursor,
;; SPACE toggles horizontal/vertical, Enter/right-click finishes.  Each
;; dropped line becomes a visible green LINE entity (temp) that later
;; carries its own dim string.  Returns (hlist vlist) where each entry
;; is (coord . ename).
(defun dsld-adim-place-lines (xmin ymin xmax ymax / gr code data cur horiz
                                                    done hl vl res le)
  (setq horiz T done nil hl nil vl nil cur nil)
  (prompt "\n[ADIM] Click to drop HORIZONTAL follow lines - Space = vertical, Enter/right-click = done: ")
  (while (not done)
    (setq gr (grread T 15 0) code (car gr) data (cadr gr))
    (cond
      ((= code 5)                          ; cursor moved - ghost line
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq cur (if horiz
                   (dsld-adim-clamp (cadr data) ymin ymax)
                   (dsld-adim-clamp (car data) xmin xmax)))
       (dsld-adim-xor cur horiz xmin ymin xmax ymax))
      ((= code 3)                          ; click - drop a line here
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq res (if horiz
                   (dsld-adim-clamp (cadr data) ymin ymax)
                   (dsld-adim-clamp (car data) xmin xmax)))
       (setq le (dsld-adim-temp-ent
                  (list '(0 . "LINE") '(62 . 3)
                        (cons 10 (if horiz (list xmin res 0.0)
                                           (list res ymin 0.0)))
                        (cons 11 (if horiz (list xmax res 0.0)
                                           (list res ymax 0.0))))))
       (if horiz
         (setq hl (cons (cons res le) hl))
         (setq vl (cons (cons res le) vl)))
       (setq cur nil))
      ((and (= code 2) (= data 32))        ; Space - toggle direction
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq cur nil horiz (not horiz))
       (prompt (if horiz
         "\n[ADIM] HORIZONTAL follow lines - click to drop, Space = vertical, Enter = done: "
         "\n[ADIM] VERTICAL follow lines - click to drop, Space = horizontal, Enter = done: ")))
      ((and (= code 2) (member data '(13 27)))  ; Enter / Esc - done
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq done T))
      ((member code '(11 25))              ; right-click - done
       (if cur (dsld-adim-xor cur horiz xmin ymin xmax ymax))
       (setq done T))
      (T nil)))
  (list (reverse hl) (reverse vl)))

;;-----------------------------------------------------------------------;;
;; Crossing collection
;;-----------------------------------------------------------------------;;

(defun dsld-adim-type-filter ()
  (strcat "LINE,LWPOLYLINE,POLYLINE,ARC,CIRCLE,ELLIPSE,SPLINE,AEC*,ACAD_PROXY*"
          (if *DSLD-ADIM-INCLUDE-INSERTS* ",INSERT" "")))

(defun dsld-adim-ent-bbox (e / obj lo hi rc)
  (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list e)))
  (if (vl-catch-all-error-p obj)
    nil
    (progn
      (setq rc (vl-catch-all-apply
                 '(lambda () (vla-GetBoundingBox obj 'lo 'hi))))
      (if (vl-catch-all-error-p rc)
        nil
        (list (vlax-safearray->list lo) (vlax-safearray->list hi))))))

;; AEC wall crossings land on the wall BASELINE - BricsCAD (and likely
;; ACA) custom entities intersect via their base curve, not their
;; component linework (ADIMTEST finding, Timsbury exterior: exactly one
;; crossing per wall, sitting 4.0/5.5 or 4.0/1.0 etc. inside the bbox).
;; DSLD justification puts the baseline ON a stud face; the stud
;; extends toward whichever bbox side fits a stud width with the
;; smallest finish-shell leftover (0-1" of rock/air; the 4" brick side
;; never fits).  Returns the list of face coords (1 or 2).
(defun dsld-adim-aec-faces (b lo hi)
  (dsld-adim-aec-faces-w b lo hi *DSLD-ADIM-STUD-WIDTHS*))

(defun dsld-adim-aec-faces-w (b lo hi widths / bestw bestl bestdir room l)
  (setq bestl 1e9 bestw nil bestdir 1.0)
  (foreach w widths
    (setq room (- hi b) l (- room w))
    (if (and (>= l (- *DSLD-ADIM-STUD-TOL*))
             (<= l (+ *DSLD-ADIM-SHELL-MAX* *DSLD-ADIM-STUD-TOL*))
             (< l bestl))
      (setq bestl l bestw w bestdir 1.0))
    (setq room (- b lo) l (- room w))
    (if (and (>= l (- *DSLD-ADIM-STUD-TOL*))
             (<= l (+ *DSLD-ADIM-SHELL-MAX* *DSLD-ADIM-STUD-TOL*))
             (< l bestl))
      (setq bestl l bestw w bestdir -1.0)))
  (if bestw
    (list b (+ b (* bestdir bestw)))
    (list b)))

;; True stud width for a wall: the DSLD style NAME is authoritative
;; (TK_Stud-3.5 Brick reports Width = 9.5, the full assembly!), else
;; trust Width when it is stud-sized (TK_Stud-X styles report the bare
;; stud - probe-verified in ACA 2027), else nil.
(defun dsld-adim-style-stud (name w / up)
  (setq up (strcase name))
  (cond
    ((wcmatch up "*STUD-3.5*") 3.5)
    ((wcmatch up "*STUD-5.5*") 5.5)
    ((and w (numberp w) (<= w 6.0)) w)
    (T nil)))

;; Baseline + stud width straight from the wall's COM properties.  ACA
;; exposes StartPoint/EndPoint/Width/StyleName on host AND xref-nested
;; walls (probe-verified); BricsCAD does not - callers must handle nil.
;; Returns (x1 y1 x2 y2 stud-width-or-nil) or nil.
(defun dsld-adim-wall-props (e / vo sp ep w sn)
  (setq vo (vl-catch-all-apply 'vlax-ename->vla-object (list e)))
  (if (vl-catch-all-error-p vo)
    nil
    (progn
      (setq sp (vl-catch-all-apply 'vlax-get (list vo 'StartPoint))
            ep (vl-catch-all-apply 'vlax-get (list vo 'EndPoint)))
      (if (or (vl-catch-all-error-p sp) (vl-catch-all-error-p ep)
              (not (listp sp)) (not (listp ep)))
        nil
        (progn
          (setq w  (vl-catch-all-apply 'vlax-get (list vo 'Width)))
          (setq sn (vl-catch-all-apply 'vlax-get (list vo 'StyleName)))
          (if (vl-catch-all-error-p w) (setq w nil))
          (if (vl-catch-all-error-p sn) (setq sn ""))
          (list (car sp) (cadr sp) (car ep) (cadr ep)
                (dsld-adim-style-stud (vl-princ-to-string sn) w)))))))

;; Crossing of segment (x1 y1)-(x2 y2) with the follow line.
;; axis 0 = horizontal line y=coord spanning lo..hi in X -> crossing X;
;; axis 1 = vertical line x=coord spanning lo..hi in Y -> crossing Y;
;; nil when they miss.
(defun dsld-adim-seg-cross (x1 y1 x2 y2 axis coord lo hi / a1 a2 b1 b2 prm v)
  (if (= axis 0)
    (setq a1 y1 a2 y2 b1 x1 b2 x2)
    (setq a1 x1 a2 x2 b1 y1 b2 y2))
  (if (or (= a1 a2) (> (* (- a1 coord) (- a2 coord)) 0.0))
    nil
    (progn
      (setq prm (/ (- coord a1) (- a2 a1)))
      (setq v (+ b1 (* prm (- b2 b1))))
      (if (and (>= v lo) (<= v hi)) v))))

;; Crossings of ONE entity with the scan-line entity's vla object.
;; Returns records (coord layer type ename); nil on any COM failure.
(defun dsld-adim-xsect (e vScan axis lay typ / obj ipts recs)
  (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list e)))
  (setq recs nil)
  (if (not (vl-catch-all-error-p obj))
    (progn
      (setq ipts (vl-catch-all-apply 'vlax-invoke
                   (list obj 'IntersectWith vScan acExtendNone)))
      (if (and ipts (not (vl-catch-all-error-p ipts)) (listp ipts))
        (while ipts
          (setq recs (cons (list (nth axis ipts) lay typ e) recs)
                ipts (cdddr ipts))))))
  recs)

;; All intersections of follow-line entity eScan with candidate wall
;; linework.  axis: 0 = report X of each crossing (horizontal line),
;; 1 = report Y (vertical line).  Returns records (coord layer type
;; ename).  ssget "_X" + bbox test, not fence - fence only sees the
;; current view (lesson learned in RPR v1.8.0).
(defun dsld-adim-collect (eScan axis / ed pA pB vScan sxmin symin sxmax symax
                                       ss n i e recs)
  (setq ed (entget eScan)
        pA (cdr (assoc 10 ed))
        pB (cdr (assoc 11 ed)))
  (setq vScan (vlax-ename->vla-object eScan))
  (setq sxmin (min (car pA) (car pB))  sxmax (max (car pA) (car pB))
        symin (min (cadr pA) (cadr pB)) symax (max (cadr pA) (cadr pB)))
  (setq ss (ssget "_X" (list (cons 0 (dsld-adim-type-filter))
                             (cons 410 (getvar "CTAB")))))
  (setq recs nil n (if ss (sslength ss) 0) i 0)
  (while (< i n)
    (setq e (ssname ss i) i (1+ i))
    (if (not (member e *DSLD-ADIM-TEMPS*))
      (setq recs (append (dsld-adim-scan-ent e vScan axis
                                             sxmin symin sxmax symax)
                         recs))))
  ;; construct overlays: walk identity xrefs so dims run in one
  ;; construct reference the other's walls too
  (if *DSLD-ADIM-XREF-WALLS*
    (setq recs (append (dsld-adim-scan-xrefs vScan axis
                                             sxmin symin sxmax symax)
                       recs)))
  recs)

;; Scan ONE entity against the follow line: class/layer via entget with
;; the COM fallback (BricsCAD's entget on AEC objects returns ONLY the
;; -1 group - without the fallback every AEC wall is silently skipped),
;; layer filter, bbox overlap, intersect, AEC one-point / face
;; expansion.  Returns records.
(defun dsld-adim-scan-ent (e vScan axis sxmin symin sxmax symax
                           / ed lay typ obj tmp bb hit ok ipts ncross
                             props cr)
  (setq ed  (entget e)
        lay (cdr (assoc 8 ed))
        typ (cdr (assoc 0 ed)))
  (if (or (null lay) (null typ))
    (progn
      (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list e)))
      (if (not (vl-catch-all-error-p obj))
        (progn
          (if (null lay)
            (progn
              (setq tmp (vl-catch-all-apply 'vlax-get (list obj 'Layer)))
              (if (not (vl-catch-all-error-p tmp)) (setq lay tmp))))
          (if (null typ)
            (progn
              (setq tmp (vl-catch-all-apply 'vlax-get (list obj 'ObjectName)))
              (if (not (vl-catch-all-error-p tmp)) (setq typ tmp))))))))
  (if (null lay) (setq lay "0"))
  (if (null typ) (setq typ "?"))
  (setq bb (dsld-adim-ent-bbox e))
  ;; bbox overlap with the follow-line segment (nil bbox = try anyway)
  (setq hit (or (null bb)
                (and (<= (car  (car bb))  sxmax)
                     (>= (car  (cadr bb)) sxmin)
                     (<= (cadr (car bb))  symax)
                     (>= (cadr (cadr bb)) symin))))
  (setq ipts nil)
  (if hit
    (progn
      (setq ok (or (dsld-adim-layok lay)
                   (and *DSLD-ADIM-INCLUDE-INSERTS*
                        (= typ "INSERT")
                        (not (dsld-adim-ignored-p lay)))))
      (setq ncross 0)
      (if ok
        (progn
          (setq props nil cr nil)
          (if (wcmatch (strcase typ) "AEC_WALL*,AECDBWALL*")
            (setq props (dsld-adim-wall-props e)))
          (cond
            ;; ACA: the wall's baseline comes straight from its COM
            ;; properties - crossing computed analytically, and the
            ;; crossing IS the justified stud face
            (props
             (setq cr (dsld-adim-seg-cross
                        (car props) (cadr props)
                        (caddr props) (cadddr props)
                        axis
                        (if (= axis 0) symin sxmin)
                        (if (= axis 0) sxmin symin)
                        (if (= axis 0) sxmax symax)))
             (cond
               ((null cr) (setq ipts nil))
               ((eq *DSLD-ADIM-WALL-POINT* 'one)
                (setq ipts (list (list cr lay "AEC-WALL-PT" e))))
               (T
                ;; 'faces: true stud width from the style + bbox side
                (if (and bb (nth 4 props)
                         (<= (- (nth axis (cadr bb)) (nth axis (car bb)))
                             12.0))
                  (setq ipts (mapcar '(lambda (f) (list f lay "AEC-FACE" e))
                                     (dsld-adim-aec-faces-w cr
                                       (nth axis (car bb))
                                       (nth axis (cadr bb))
                                       (list (nth 4 props)))))
                  (setq ipts (list (list cr lay "AEC-WALL-PT" e)))))))
            ;; BricsCAD: no wall properties - IntersectWith returns the
            ;; baseline (one crossing = the signature); multiple
            ;; crossings mean real linework was intersected
            (T
             (setq ipts (dsld-adim-xsect e vScan axis lay typ))
             (if (and (wcmatch (strcase typ) "AEC_WALL*,AECDBWALL*")
                      bb
                      (= 1 (length ipts))
                      (<= (- (nth axis (cadr bb)) (nth axis (car bb))) 12.0))
               (if (eq *DSLD-ADIM-WALL-POINT* 'one)
                 (setq ipts (list (list (car (car ipts)) lay
                                        "AEC-WALL-PT" e)))
                 (setq ipts
                       (mapcar '(lambda (f) (list f lay "AEC-FACE" e))
                               (dsld-adim-aec-faces
                                 (car (car ipts))
                                 (nth axis (car bb))
                                 (nth axis (cadr bb)))))))))
          (setq ncross (length ipts))))
      (if *DSLD-ADIM-DIAG*
        (setq *DSLD-ADIM-DIAG-ROWS*
              (cons (list typ lay (if ok "scanned" "layer-skipped") ncross)
                    *DSLD-ADIM-DIAG-ROWS*)))))
  ipts)

;; Walls inside attached xrefs.  The DSLD constructs overlay at
;; IDENTITY (0,0, no rotation, scale 1), so nested geometry aligns with
;; the host space.  Nested entities CANNOT be intersected directly -
;; BricsCAD returns no points across databases (probe-verified) - but
;; intersecting the xref INSERT itself works and yields every nested
;; crossing.  Each point is then attributed to the nested WALL whose
;; bbox contains it (wall bboxes are gathered once per command and
;; cached); unattributed points (notes, tags, glazing) are dropped.

;; cached (lo hi layer) boxes for wall-layer entities in xref block bn;
;; boxes thicker than 12" both ways (diagonal walls, big blocks) are
;; skipped, same limitation as the direct AEC path
(defun dsld-adim-xref-wallboxes (bn / hit brec be vo lay bb boxes w h)
  (setq hit (assoc bn *DSLD-ADIM-XREF-CACHE*))
  (if hit
    (cdr hit)
    (progn
      (setq brec (tblsearch "BLOCK" bn))
      (setq be (if brec (cdr (assoc -2 brec))))
      (setq boxes nil)
      (while be
        (setq vo (vl-catch-all-apply 'vlax-ename->vla-object (list be)))
        (if (not (vl-catch-all-error-p vo))
          (progn
            (setq lay (vl-catch-all-apply 'vlax-get (list vo 'Layer)))
            (if (vl-catch-all-error-p lay) (setq lay "0"))
            (if (dsld-adim-layok lay)
              (progn
                (setq bb (dsld-adim-ent-bbox be))
                (if bb
                  (progn
                    (setq w (- (car  (cadr bb)) (car  (car bb)))
                          h (- (cadr (cadr bb)) (cadr (car bb))))
                    (if (or (<= w 12.0) (<= h 12.0))
                      (setq boxes (cons (list (car bb) (cadr bb) lay)
                                        boxes)))))))))
        (setq be (entnext be)))
      (setq *DSLD-ADIM-XREF-CACHE*
            (cons (cons bn boxes) *DSLD-ADIM-XREF-CACHE*))
      boxes)))

;; cached baseline SEGMENTS for wall-layer entities in xref block bn:
;; (x1 y1 x2 y2 stud-or-nil layer).  AEC walls contribute their COM
;; baseline (ACA); plain LINEs their endpoints (flattened xrefs, works
;; everywhere).  Gathered once per command - scans after the first are
;; pure math.
(defun dsld-adim-xref-segs (bn / hit brec be vo on lay props sp ep segs)
  (setq hit (assoc bn *DSLD-ADIM-XSEG-CACHE*))
  (if hit
    (cdr hit)
    (progn
      (setq brec (tblsearch "BLOCK" bn))
      (setq be (if brec (cdr (assoc -2 brec))))
      (setq segs nil)
      (while be
        (setq vo (vl-catch-all-apply 'vlax-ename->vla-object (list be)))
        (if (not (vl-catch-all-error-p vo))
          (progn
            (setq on (vl-catch-all-apply 'vlax-get (list vo 'ObjectName)))
            (setq on (if (vl-catch-all-error-p on) ""
                         (strcase (vl-princ-to-string on))))
            (setq lay (vl-catch-all-apply 'vlax-get (list vo 'Layer)))
            (if (vl-catch-all-error-p lay) (setq lay "0"))
            (cond
              ;; AEC walls: the class is authoritative - only the
              ;; ignore list applies (nested .Layer is platform-flaky)
              ((and (wcmatch on "*WALL*")
                    (not (dsld-adim-ignored-p lay)))
               (setq props (dsld-adim-wall-props be))
               (if props
                 (setq segs (cons (list (car props) (cadr props)
                                        (caddr props) (cadddr props)
                                        (nth 4 props) lay)
                                  segs))))
              ;; plain linework (flattened xrefs): full layer filter
              ((and (wcmatch on "*DBLINE")
                    (dsld-adim-layok lay))
               (setq sp (vl-catch-all-apply 'vlax-get
                                            (list vo 'StartPoint))
                     ep (vl-catch-all-apply 'vlax-get
                                            (list vo 'EndPoint)))
               (if (and (not (vl-catch-all-error-p sp))
                        (not (vl-catch-all-error-p ep))
                        (listp sp) (listp ep))
                 (setq segs (cons (list (car sp) (cadr sp)
                                        (car ep) (cadr ep)
                                        nil lay)
                                  segs)))))))
        (setq be (entnext be)))
      (setq *DSLD-ADIM-XSEG-CACHE*
            (cons (cons bn segs) *DSLD-ADIM-XSEG-CACHE*))
      segs)))

(defun dsld-adim-scan-xrefs (vScan axis sxmin symin sxmax symax
                             / ss i e ed bn brec flag ip rot sx sy vIns ipts
                               px py boxes b matched recs seen segs s cr)
  (setq recs nil seen nil)
  (setq ss (ssget "_X" '((0 . "INSERT"))))
  (setq i 0)
  (if ss
    (while (< i (sslength ss))
      (setq e (ssname ss i) i (1+ i))
      (setq ed  (entget e)
            bn  (cdr (assoc 2 ed))
            ip  (cdr (assoc 10 ed))
            rot (cdr (assoc 50 ed))
            sx  (cdr (assoc 41 ed))
            sy  (cdr (assoc 42 ed)))
      (setq brec (if bn (tblsearch "BLOCK" bn)))
      (setq flag (if brec (cdr (assoc 70 brec)) 0))
      (if (and brec
               (= 4 (logand 4 flag))             ; xref block
               (not (member bn seen))
               ip
               (< (abs (car ip)) 0.001)
               (< (abs (cadr ip)) 0.001)
               (or (null rot) (< (abs rot) 0.0001))
               (or (null sx) (equal sx 1.0 0.0001))
               (or (null sy) (equal sy 1.0 0.0001)))
        (progn
          (setq seen (cons bn seen))
          (setq segs (dsld-adim-xref-segs bn))
          (cond
            ;; ACA (and flattened xrefs anywhere): analytic crossings
            ;; against the cached baseline segments
            (segs
             (foreach s segs
               (setq cr (dsld-adim-seg-cross
                          (car s) (cadr s) (caddr s) (cadddr s)
                          axis
                          (if (= axis 0) symin sxmin)
                          (if (= axis 0) sxmin symin)
                          (if (= axis 0) sxmax symax)))
               (if cr
                 (setq recs (cons (list cr (nth 5 s)
                                        (if (nth 4 s) "XREF-WALL-PT"
                                                      "XREF-LINE")
                                        e)
                                  recs)))))
            ;; BricsCAD AEC xrefs: nested properties unavailable -
            ;; intersect the INSERT itself and attribute each point to
            ;; the nested wall bbox that contains it
            (T
             (setq vIns (vl-catch-all-apply 'vlax-ename->vla-object
                                            (list e)))
             (if (not (vl-catch-all-error-p vIns))
               (progn
                 (setq ipts (vl-catch-all-apply 'vlax-invoke
                              (list vIns 'IntersectWith vScan
                                    acExtendNone)))
                 (if (and ipts (not (vl-catch-all-error-p ipts))
                          (listp ipts))
                   (progn
                     (setq boxes (dsld-adim-xref-wallboxes bn))
                     (while ipts
                       (setq px (car ipts) py (cadr ipts))
                       (setq matched nil)
                       (foreach b boxes
                         (if (and (not matched)
                                  (<= (- (car  (car b)) 0.1) px)
                                  (<= px (+ (car  (cadr b)) 0.1))
                                  (<= (- (cadr (car b)) 0.1) py)
                                  (<= py (+ (cadr (cadr b)) 0.1)))
                           (setq matched b)))
                       (if matched
                         (setq recs (cons (list (if (= axis 0) px py)
                                                (caddr matched)
                                                "XREF-WALL" e)
                                          recs)))
                       (setq ipts (cdddr ipts)))))))))))))
  recs)

;;-----------------------------------------------------------------------;;
;; Stud-face resolution
;;-----------------------------------------------------------------------;;

;; Reduce one crossing cluster (records sorted by coord) to stud faces.
;; Iteratively extracts EVERY stud-width pair (so double walls and
;; chases keep all their faces), then keeps any leftover crossing that
;; sits exactly a stud width from a kept face (stacked stud runs
;; sharing a face).  Remaining leftovers are finish lines - dropped.
;; Returns (kept-records dropped-pairs), dropped pair = (record . reason).
(defun dsld-adim-pick-faces (cl / n remaining kept drops best bestd i j a b
                                  sep d near inset one)
  (setq n (length cl)
        one (eq *DSLD-ADIM-WALL-POINT* 'one)
        drops nil)
  (cond
    ((< n 2) (list cl nil))
    (T
     (setq remaining cl kept nil best T)
     (while best
       (setq best nil bestd 1e9 n (length remaining) i 0)
       (while (< i n)
         (setq j (1+ i))
         (while (< j n)
           (setq a (nth i remaining) b (nth j remaining)
                 sep (- (car b) (car a)))
           (foreach w *DSLD-ADIM-STUD-WIDTHS*
             (setq d (abs (- sep w)))
             (if (and (<= d *DSLD-ADIM-STUD-TOL*) (< d bestd))
               (setq best (list a b) bestd d)))
           (setq j (1+ j)))
         (setq i (1+ i)))
       (if best
         (progn
           ;; 'one: the pair is one wall - keep its lower face only
           (if one
             (setq kept  (append kept (list (car best)))
                   drops (cons (cons (cadr best)
                                     "opposite stud face (one point per wall)")
                               drops))
             (setq kept (append kept best)))
           (setq remaining (vl-remove-if '(lambda (r) (member r best))
                                         remaining)))))
     (cond
       (kept
        ;; chain rule ('faces only): leftover a stud width from a kept
        ;; face = stacked run sharing that face
        (if (not one)
          (progn
            (foreach r remaining
              (setq near nil)
              (foreach k kept
                (foreach w *DSLD-ADIM-STUD-WIDTHS*
                  (if (<= (abs (- (abs (- (car r) (car k))) w))
                          *DSLD-ADIM-STUD-TOL*)
                    (setq near T))))
              (if near (setq kept (cons r kept))))
            (setq remaining (vl-remove-if '(lambda (r) (member r kept))
                                          remaining))))
        (setq kept (vl-sort kept '(lambda (p q) (< (car p) (car q)))))
        (list kept
              (append
                (mapcar '(lambda (r)
                           (cons r "not a stud face (stud pair found)"))
                        remaining)
                drops)))
       (T
        ;; no stud pair - rock faces only?  outermost pair at stud + 2x gyp
        (setq a (car cl) b (last cl) sep (- (car b) (car a)) inset nil)
        (foreach w *DSLD-ADIM-STUD-WIDTHS*
          (if (and (not inset)
                   (<= (abs (- sep (+ w (* 2.0 *DSLD-ADIM-GYP*))))
                       *DSLD-ADIM-STUD-TOL*))
            (setq inset T)))
        (if inset
          (list
            (if one
              (list (list (+ (car a) *DSLD-ADIM-GYP*) (cadr a) "INSET"
                          (nth 3 a)))
              (list (list (+ (car a) *DSLD-ADIM-GYP*) (cadr a) "INSET"
                          (nth 3 a))
                    (list (- (car b) *DSLD-ADIM-GYP*) (cadr b) "INSET"
                          (nth 3 b))))
            (append
              (mapcar '(lambda (r) (cons r "sheetrock face (inset to stud)"))
                      (list a b))
              (mapcar '(lambda (r) (cons r "inner finish line"))
                      (vl-remove-if '(lambda (r) (member r (list a b))) cl))))
          ;; unknown assembly - keep everything, user discards
          (list cl nil)))))))

;; Sort, fuzz-dedupe, cluster, resolve.  Returns (kept dropped-pairs).
(defun dsld-adim-resolve (recs / sorted out drops prev r clusters cluster res
                                 kept pts raw)
  (setq sorted (vl-sort recs '(lambda (a b) (< (car a) (car b)))))
  ;; fuzz-dedupe against the last kept record
  (setq out nil prev nil drops nil)
  (foreach r sorted
    (if (and prev (<= (- (car r) (car prev)) *DSLD-ADIM-FUZZ*))
      (setq drops (cons (cons r "duplicate crossing") drops))
      (setq out (cons r out) prev r)))
  (setq sorted (reverse out))
  ;; cluster: successive crossings closer than the cluster gap belong
  ;; to one wall assembly
  (setq clusters nil cluster nil)
  (foreach r sorted
    (cond
      ((null cluster) (setq cluster (list r)))
      ((<= (- (car r) (car (last cluster))) *DSLD-ADIM-CLUSTER-GAP*)
       (setq cluster (append cluster (list r))))
      (T (setq clusters (cons cluster clusters) cluster (list r)))))
  (if cluster (setq clusters (cons cluster clusters)))
  (setq clusters (reverse clusters))
  ;; resolve each cluster to stud faces.  Records typed *-PT
  ;; (AEC-WALL-PT / XREF-WALL-PT) are AUTHORITATIVE single wall points -
  ;; two different walls' baselines can legitimately sit a stud width
  ;; apart (interior abutting exterior), so they are exempt from the
  ;; pair-collapse logic; only raw linework crossings get resolved.
  (setq kept nil)
  (foreach cluster clusters
    (setq pts (vl-remove-if-not
                '(lambda (r) (wcmatch (vl-princ-to-string (caddr r)) "*-PT"))
                cluster))
    (setq raw (vl-remove-if '(lambda (r) (member r pts)) cluster))
    (setq kept (append kept pts))
    (if raw
      (progn
        (setq res (dsld-adim-pick-faces raw))
        (setq kept  (append kept (car res))
              drops (append drops (cadr res))))))
  (setq kept (vl-sort kept '(lambda (p q) (< (car p) (car q)))))
  (list kept drops))

;; The two resolved stud points that bracket coordinate v - (lo hi), or
;; nil when v isn't between two walls (or sits exactly on one).
(defun dsld-adim-bracket (coords v / lo hi)
  (foreach c coords
    (if (<= c v) (if (or (null lo) (> c lo)) (setq lo c)))
    (if (>= c v) (if (or (null hi) (< c hi)) (setq hi c))))
  (if (and lo hi (< lo hi)) (list lo hi)))

;;-----------------------------------------------------------------------;;
;; Dimension creation
;;-----------------------------------------------------------------------;;

;; One linear dim.  Returns the new ename, or nil if the command
;; produced nothing.
(defun dsld-adim-dimlinear (p1 p2 horiz ploc / before e)
  (setq before (entlast))
  (command "_.DIMLINEAR" "_non" p1 "_non" p2
           (if horiz "_H" "_V") "_non" ploc)
  (setq e (entlast))
  (if (not (eq e before)) e nil))

;; Chain string along one follow line.  coords are the stud points IN
;; ORDER (ascending = left-to-right, descending = rear-to-front);
;; fixed = the follow line's coordinate - the dim string sits ON the
;; line (DSLD dims run along the plan, not stacked outside it).  The
;; overall dim, if warranted, goes at row2 (offset toward the nearer
;; box edge, computed by the caller).
;; Returns (chain overall): chain is positionally aligned with the
;; coord pairs (nil where a dim failed) so each follow-line segment
;; maps to its dim; overall is the overall's ename or nil.
(defun dsld-adim-string (coords horiz fixed row2 / chain a mid e o1 o2 om oa)
  (setq chain nil a (car coords))
  (foreach b (cdr coords)
    (setq mid (/ (+ a b) 2.0))
    (setq e (if horiz
              (dsld-adim-dimlinear (list a fixed 0.0) (list b fixed 0.0)
                                   T (list mid fixed 0.0))
              (dsld-adim-dimlinear (list fixed a 0.0) (list fixed b 0.0)
                                   nil (list fixed mid 0.0))))
    (setq chain (cons e chain))
    (setq a b))
  (setq chain (reverse chain) oa nil)
  (if (and *DSLD-ADIM-OVERALL* (> (length coords) 2))
    (progn
      (setq o1 (car coords) o2 (last coords) om (/ (+ o1 o2) 2.0))
      (setq oa (if horiz
                 (dsld-adim-dimlinear (list o1 fixed 0.0) (list o2 fixed 0.0)
                                      T (list om row2 0.0))
                 (dsld-adim-dimlinear (list fixed o1 0.0) (list fixed o2 0.0)
                                      nil (list row2 om 0.0))))))
  (list chain oa))

;; Split a follow line into per-dim SEGMENTS between the stud points -
;; the discard gizmo: instead of hunting dim entities, the user clicks
;; the piece of the follow line whose dim they don't want.  Returns
;; ((segE . dimE) ...) skipping pairs whose dim failed.
(defun dsld-adim-segments (coords horiz fixed chain / segs k a segE dimE)
  (setq segs nil k 0 a (car coords))
  (foreach b (cdr coords)
    (setq segE (dsld-adim-temp-ent
                 (list '(0 . "LINE") '(62 . 3)
                       (cons 10 (if horiz (list a fixed 0.0)
                                          (list fixed a 0.0)))
                       (cons 11 (if horiz (list b fixed 0.0)
                                          (list fixed b 0.0))))))
    (setq dimE (nth k chain))
    (if dimE (setq segs (cons (cons segE dimE) segs)))
    (setq k (1+ k) a b))
  segs)

;; Activate the DSLD dimstyle if it exists; stash the current one.
(defun dsld-adim-use-dimstyle ( / rc)
  (if (and *DSLD-ADIM-DIMSTYLE*
           (tblsearch "DIMSTYLE" *DSLD-ADIM-DIMSTYLE*)
           (/= (strcase *DSLD-ADIM-DIMSTYLE*) (strcase (getvar "DIMSTYLE"))))
    (progn
      (dsld-adim-stash 'dimstyle (getvar "DIMSTYLE"))
      (setq rc (vl-catch-all-apply 'dsld-adim-set-dimstyle-by-name
                                   (list *DSLD-ADIM-DIMSTYLE*)))
      (if (vl-catch-all-error-p rc)
        (dsld-adim-msg (strcat "could not activate dimstyle "
                               *DSLD-ADIM-DIMSTYLE* " - using current."))))))

;;-----------------------------------------------------------------------;;
;; Discard pass - the follow line stays put, split into SEGMENTS at the
;; stud points: click the segment whose dim you don't want (segment and
;; dim highlight; click again to unmark), Space switches horizontal /
;; vertical, Enter deletes everything marked.  Esc backs out keeping
;; all.  Clicking an overall dim itself works too.
;;-----------------------------------------------------------------------;;

(defun dsld-adim-discard (segsH segsV allH allV / phase marked done apply gr
                                                  code data pt tol ss i e
                                                  hit hseg pr mk n)
  (if (or allH allV)
    (progn
      (setq phase 'h marked nil done nil apply nil)
      (prompt "\n[ADIM] DISCARD - click the HORIZONTAL segments you don't want dims on (click again to unmark), Space = vertical, Enter = delete marked, Esc = keep all: ")
      (while (not done)
        (setq gr (grread T 15 0) code (car gr) data (cadr gr))
        (cond
          ((= code 3)                      ; click - mark/unmark a segment
           (setq pt data tol (/ (getvar "VIEWSIZE") 60.0))
           (setq ss (ssget "_C"
                           (list (- (car pt) tol) (- (cadr pt) tol) 0.0)
                           (list (+ (car pt) tol) (+ (cadr pt) tol) 0.0)
                           '((0 . "LINE,DIMENSION"))))
           (setq hit nil hseg nil)
           (if ss
             (progn
               (setq i 0)
               (while (and (< i (sslength ss)) (not hit))
                 (setq e (ssname ss i) i (1+ i))
                 (cond
                   ((setq pr (assoc e (if (eq phase 'h) segsH segsV)))
                    (setq hseg e hit (cdr pr)))
                   ((member e (if (eq phase 'h) allH allV))
                    (setq hit e))))))
           (cond
             ((null hit)
              (prompt (strcat "\n[ADIM] no "
                              (if (eq phase 'h) "horizontal" "vertical")
                              " ADIM segment there - Space switches direction.")))
             ((setq mk (assoc hit marked))
              (setq marked (vl-remove mk marked))
              (redraw hit 4)
              (if (cdr mk) (redraw (cdr mk) 4)))
             (T
              (setq marked (cons (cons hit hseg) marked))
              (redraw hit 3)
              (if hseg (redraw hseg 3)))))
          ((and (= code 2) (= data 32))    ; Space - toggle direction
           (setq phase (if (eq phase 'h) 'v 'h))
           (prompt (if (eq phase 'h)
             "\n[ADIM] marking HORIZONTAL segments - Space = vertical, Enter = delete marked: "
             "\n[ADIM] marking VERTICAL segments - Space = horizontal, Enter = delete marked: ")))
          ((and (= code 2) (= data 13))    ; Enter - apply
           (setq done T apply T))
          ((member code '(11 25))          ; right-click - apply
           (setq done T apply T))
          ((and (= code 2) (= data 27))    ; Esc - keep all
           (setq done T))
          (T nil)))
      (if apply
        (progn
          (setq n 0)
          (foreach mk marked
            (if (entget (car mk))
              (progn (entdel (car mk)) (setq n (1+ n))))
            (if (and (cdr mk) (entget (cdr mk))) (entdel (cdr mk))))
          (dsld-adim-msg (strcat (itoa n) " dimension(s) discarded, "
                                 (itoa (- (+ (length allH) (length allV)) n))
                                 " kept.")))
        (progn
          (foreach mk marked
            (redraw (car mk) 4)
            (if (cdr mk) (redraw (cdr mk) 4)))
          (dsld-adim-msg "discard cancelled - all dimensions kept.")))))
  (princ))

;;-----------------------------------------------------------------------;;
;; ADIM - main command
;;-----------------------------------------------------------------------;;

(defun c:ADIM ( / *error* p1 p2 xmin ymin xmax ymax lines hls vls
                 yScan xScan res kept drops coords allH allV segsH segsV
                 sr chain row2)
  (setq *error* dsld-adim-cmd-error)
  (setq *DSLD-ADIM-CLEANUP* nil *DSLD-ADIM-TEMPS* nil)
  (dsld-adim-stash 'cmdecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  (command "_.UNDO" "_Begin")
  (dsld-adim-stash 'undo T)
  (setq p1 (getpoint "\n[ADIM] Auto dim - first corner of boundary box: "))
  (if p1 (setq p2 (getcorner p1 "\n[ADIM] Opposite corner: ")))
  (cond
    ((not (and p1 p2)) (dsld-adim-msg "cancelled."))
    (T
     (setq xmin (min (car p1) (car p2)) xmax (max (car p1) (car p2))
           ymin (min (cadr p1) (cadr p2)) ymax (max (cadr p1) (cadr p2)))
     (setq *DSLD-ADIM-LAST-BBOX* (list (list xmin ymin) (list xmax ymax)))
     ;; visible boundary box
     (dsld-adim-temp-ent
       (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(62 . 2)
             '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
             (cons 10 (list xmin ymin)) (cons 10 (list xmax ymin))
             (cons 10 (list xmax ymax)) (cons 10 (list xmin ymax))))
     ;; follow lines: click drops one, Space toggles H/V, Enter done
     (setq lines (dsld-adim-place-lines xmin ymin xmax ymax)
           hls (car lines) vls (cadr lines))
     (if (not (or hls vls))
       (dsld-adim-msg "no follow lines placed - nothing to dimension.")
       (progn
         (dsld-adim-stash 'clayer (getvar "CLAYER"))
         (dsld-adim-ensure-layer *DSLD-ADIM-DIM-LAYER*)
         (setvar "CLAYER" *DSLD-ADIM-DIM-LAYER*)
         (dsld-adim-stash 'osmode (getvar "OSMODE"))
         (setvar "OSMODE" 0)
         (dsld-adim-use-dimstyle)
         (setq allH nil allV nil segsH nil segsV nil)
         ;; LEFT -> RIGHT strings (one per horizontal follow line)
         (foreach ln hls
           (setq yScan (car ln))
           (setq res   (dsld-adim-resolve (dsld-adim-collect (cdr ln) 0))
                 kept  (car res)
                 drops (cadr res)
                 coords (mapcar 'car kept))
           (if (< (length coords) 2)
             (dsld-adim-msg (strcat "H line at " (rtos yScan 2 1) ": only "
                                    (itoa (length coords))
                                    " stud point(s) - string skipped."))
             (progn
               ;; overall goes toward the nearer box edge
               (setq row2 (if (< (- yScan ymin) (- ymax yScan))
                            (- yScan *DSLD-ADIM-OVERALL-OFF*)
                            (+ yScan *DSLD-ADIM-OVERALL-OFF*)))
               (setq sr    (dsld-adim-string coords T yScan row2)
                     chain (car sr))
               (setq allH (append allH (vl-remove nil chain)
                                  (if (cadr sr) (list (cadr sr)))))
               ;; swap the follow line for its per-dim segments
               (entdel (cdr ln))
               (setq segsH (append segsH
                                   (dsld-adim-segments coords T yScan chain)))
               (dsld-adim-msg (strcat "left-to-right at " (rtos yScan 2 1)
                                      ": " (itoa (length coords))
                                      " stud points, "
                                      (itoa (length drops))
                                      " crossing(s) filtered.")))))
         ;; REAR -> FRONT strings (one per vertical follow line)
         (foreach ln vls
           (setq xScan (car ln))
           (setq res   (dsld-adim-resolve (dsld-adim-collect (cdr ln) 1))
                 kept  (car res)
                 drops (cadr res)
                 coords (reverse (mapcar 'car kept)))  ; rear (top) first
           (if (< (length coords) 2)
             (dsld-adim-msg (strcat "V line at " (rtos xScan 2 1) ": only "
                                    (itoa (length coords))
                                    " stud point(s) - string skipped."))
             (progn
               (setq row2 (if (< (- xScan xmin) (- xmax xScan))
                            (- xScan *DSLD-ADIM-OVERALL-OFF*)
                            (+ xScan *DSLD-ADIM-OVERALL-OFF*)))
               (setq sr    (dsld-adim-string coords nil xScan row2)
                     chain (car sr))
               (setq allV (append allV (vl-remove nil chain)
                                  (if (cadr sr) (list (cadr sr)))))
               (entdel (cdr ln))
               (setq segsV (append segsV
                                   (dsld-adim-segments coords nil xScan chain)))
               (dsld-adim-msg (strcat "rear-to-front at " (rtos xScan 2 1)
                                      ": " (itoa (length coords))
                                      " stud points, "
                                      (itoa (length drops))
                                      " crossing(s) filtered.")))))
         ;; discard pass - click follow-line segments, H first, Space = V
         (if (or allH allV)
           (progn
             (dsld-adim-msg (strcat (itoa (+ (length allH) (length allV)))
                                    " dimension(s) placed."))
             (dsld-adim-discard segsH segsV allH allV))
           (dsld-adim-msg "no dimensions were created."))))))
  (dsld-adim-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; ADIMROOM - click inside a room and a single dim appears across it,
;; between the two stud points that bracket the click.  Space toggles
;; horizontal/vertical, Enter/right-click finishes.  The dim string
;; runs right through the clicked point.
;;-----------------------------------------------------------------------;;

;; short XOR ghost through the cursor showing the dim direction
(defun dsld-adim-room-xor (p horiz / x y)
  (setq x (car p) y (cadr p))
  (if horiz
    (grdraw (list (- x 48.0) y 0.0) (list (+ x 48.0) y 0.0) -1)
    (grdraw (list x (- y 48.0) 0.0) (list x (+ y 48.0) 0.0) -1)))

;; probe out from the click, resolve stud points, dim the bracketing
;; pair.  Returns the dim ename or nil.
(defun dsld-adim-room-dim (pt horiz / px py scanE res coords br e)
  (setq px (car pt) py (cadr pt))
  (setq scanE (dsld-adim-temp-ent
                (list '(0 . "LINE")
                      (cons 10 (if horiz
                                 (list (- px *DSLD-ADIM-ROOM-SPAN*) py 0.0)
                                 (list px (- py *DSLD-ADIM-ROOM-SPAN*) 0.0)))
                      (cons 11 (if horiz
                                 (list (+ px *DSLD-ADIM-ROOM-SPAN*) py 0.0)
                                 (list px (+ py *DSLD-ADIM-ROOM-SPAN*) 0.0))))))
  (setq res (dsld-adim-resolve (dsld-adim-collect scanE (if horiz 0 1))))
  (setq coords (mapcar 'car (car res)))
  (entdel scanE)
  (setq br (dsld-adim-bracket coords (if horiz px py)))
  (if br
    (setq e (if horiz
              (dsld-adim-dimlinear
                (list (car br) py 0.0) (list (cadr br) py 0.0)
                T (list (/ (+ (car br) (cadr br)) 2.0) py 0.0))
              (dsld-adim-dimlinear
                (list px (car br) 0.0) (list px (cadr br) 0.0)
                nil (list px (/ (+ (car br) (cadr br)) 2.0) 0.0))))
    (progn
      (dsld-adim-msg "no walls bracket that point - no dim.")
      (setq e nil)))
  e)

(defun c:ADIMROOM ( / *error* done gr code data pt horiz e made cur)
  (setq *error* dsld-adim-cmd-error)
  (setq *DSLD-ADIM-CLEANUP* nil *DSLD-ADIM-TEMPS* nil)
  (dsld-adim-stash 'cmdecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  (command "_.UNDO" "_Begin")
  (dsld-adim-stash 'undo T)
  (dsld-adim-stash 'clayer (getvar "CLAYER"))
  (dsld-adim-ensure-layer *DSLD-ADIM-DIM-LAYER*)
  (setvar "CLAYER" *DSLD-ADIM-DIM-LAYER*)
  (dsld-adim-stash 'osmode (getvar "OSMODE"))
  (setvar "OSMODE" 0)
  (dsld-adim-use-dimstyle)
  (setq horiz T done nil made 0 cur nil)
  (prompt "\n[ADIM] Click inside a room for a HORIZONTAL dim - Space = vertical, Enter = done: ")
  (while (not done)
    (setq gr (grread T 15 0) code (car gr) data (cadr gr))
    (cond
      ((= code 5)
       (if cur (dsld-adim-room-xor cur horiz))
       (setq cur data)
       (dsld-adim-room-xor cur horiz))
      ((= code 3)
       (if cur (progn (dsld-adim-room-xor cur horiz) (setq cur nil)))
       (setq pt data)
       (setq e (dsld-adim-room-dim pt horiz))
       (if e (setq made (1+ made))))
      ((and (= code 2) (= data 32))
       (if cur (progn (dsld-adim-room-xor cur horiz) (setq cur nil)))
       (setq horiz (not horiz))
       (prompt (if horiz
         "\n[ADIM] HORIZONTAL room dims - Space = vertical, Enter = done: "
         "\n[ADIM] VERTICAL room dims - Space = horizontal, Enter = done: ")))
      ((and (= code 2) (member data '(13 27)))
       (if cur (dsld-adim-room-xor cur horiz))
       (setq done T))
      ((member code '(11 25))
       (if cur (dsld-adim-room-xor cur horiz))
       (setq done T))
      (T nil)))
  (dsld-adim-msg (strcat (itoa made) " room dimension(s) placed."))
  (dsld-adim-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; ADIMLAYERS - set the include-layer filter from picked samples
;;-----------------------------------------------------------------------;;

(defun c:ADIMLAYERS ( / ss i e lay lays)
  (prompt "\n[ADIM] Pick sample entities on the layers ADIM should dimension to (Enter = clear filter): ")
  (setq ss (ssget))
  (if ss
    (progn
      (setq i 0 lays nil)
      (while (< i (sslength ss))
        (setq e   (ssname ss i) i (1+ i)
              lay (cdr (assoc 8 (entget e))))
        (if (not (member lay lays)) (setq lays (cons lay lays))))
      (setq *DSLD-ADIM-LAYERS* lays)
      (dsld-adim-msg (strcat "dimensioning only: " (dsld-adim-join lays ", "))))
    (progn
      (setq *DSLD-ADIM-LAYERS* nil)
      (dsld-adim-msg "layer filter cleared - any layer not on the ignore list.")))
  (princ))

;;-----------------------------------------------------------------------;;
;; ADIMDIAG - crossing census (the SCHDIAG drill: run on a production
;; drawing, send ADIMDIAG-report.txt back, and the stud-face logic gets
;; hardened against what the real walls expose)
;;-----------------------------------------------------------------------;;

(defun dsld-adim-diag-axis (scanE axis label f / res kept drops rows r agg key
                                                 hit)
  (setq *DSLD-ADIM-DIAG* T *DSLD-ADIM-DIAG-ROWS* nil)
  (setq res (dsld-adim-resolve (dsld-adim-collect scanE axis)))
  (setq *DSLD-ADIM-DIAG* nil)
  (setq kept (car res) drops (cadr res))
  (princ (strcat "\n\n=== " label " ===") f)
  ;; candidate census, aggregated by type/layer/status
  (setq agg nil)
  (foreach r *DSLD-ADIM-DIAG-ROWS*
    (setq key (list (car r) (cadr r) (caddr r)))
    (setq hit (assoc key agg))
    (if hit
      (setq agg (subst (list key (+ (cadr hit) 1) (+ (caddr hit) (cadddr r)))
                       hit agg))
      (setq agg (cons (list key 1 (cadddr r)) agg))))
  (princ "\nCandidates crossing the follow line's reach:" f)
  (foreach r (reverse agg)
    (princ (strcat "\n  " (caar r) "  on " (cadar r) "  [" (caddar r) "]  x"
                   (itoa (cadr r)) " ents, " (itoa (caddr r)) " crossing(s)")
           f))
  (princ (strcat "\nKept as stud faces (" (itoa (length kept)) "):") f)
  (foreach r kept
    (princ (strcat "\n  " (rtos (car r) 4 4) "  (" (rtos (car r) 2 4) ")  "
                   (caddr r) " on " (cadr r))
           f))
  (princ (strcat "\nFiltered out (" (itoa (length drops)) "):") f)
  (foreach r drops
    (princ (strcat "\n  " (rtos (caar r) 4 4) "  " (caddr (car r)) " on "
                   (cadr (car r)) "  -> " (cdr r))
           f))
  (princ))

(defun c:ADIMDIAG ( / *error* p1 p2 xmin ymin xmax ymax yScan xScan scanE
                     path f)
  (setq *error* dsld-adim-cmd-error)
  (setq *DSLD-ADIM-CLEANUP* nil *DSLD-ADIM-TEMPS* nil)
  (dsld-adim-stash 'cmdecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  (command "_.UNDO" "_Begin")
  (dsld-adim-stash 'undo T)
  (setq p1 (getpoint "\n[ADIM] DIAG - first corner of boundary box: "))
  (if p1 (setq p2 (getcorner p1 "\n[ADIM] Opposite corner: ")))
  (if (and p1 p2)
    (progn
      (setq xmin (min (car p1) (car p2)) xmax (max (car p1) (car p2))
            ymin (min (cadr p1) (cadr p2)) ymax (max (cadr p1) (cadr p2)))
      (dsld-adim-temp-ent
        (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(62 . 2)
              '(100 . "AcDbPolyline") '(90 . 4) '(70 . 1)
              (cons 10 (list xmin ymin)) (cons 10 (list xmax ymin))
              (cons 10 (list xmax ymax)) (cons 10 (list xmin ymax))))
      (setq path (strcat (getvar "DWGPREFIX") "ADIMDIAG-report.txt"))
      (setq f (open path "w"))
      (if (null f)
        (dsld-adim-msg (strcat "cannot write " path " - DIAG aborted."))
        (progn
          (princ (strcat "ADIM v" *DSLD-ADIM-VERSION* " diagnostic - "
                         (getvar "DWGNAME"))
                 f)
          (princ (strcat "\nInclude layers: "
                         (if *DSLD-ADIM-LAYERS*
                           (dsld-adim-join *DSLD-ADIM-LAYERS* ", ")
                           "(all except ignore list)"))
                 f)
          (princ (strcat "\nStud widths: "
                         (dsld-adim-join (mapcar '(lambda (w) (rtos w 2 2))
                                                 *DSLD-ADIM-STUD-WIDTHS*)
                                         ", ")
                         "  tol " (rtos *DSLD-ADIM-STUD-TOL* 2 3)
                         "  gyp " (rtos *DSLD-ADIM-GYP* 2 3)
                         "  cluster gap " (rtos *DSLD-ADIM-CLUSTER-GAP* 2 2))
                 f)
          (setq yScan (dsld-adim-drag xmin ymin xmax ymax T))
          (if yScan
            (progn
              (setq scanE (dsld-adim-temp-ent
                            (list '(0 . "LINE") '(62 . 3)
                                  (cons 10 (list xmin yScan 0.0))
                                  (cons 11 (list xmax yScan 0.0)))))
              (dsld-adim-diag-axis scanE 0 "HORIZONTAL follow line (left-to-right)" f)))
          (setq xScan (dsld-adim-drag xmin ymin xmax ymax nil))
          (if xScan
            (progn
              (setq scanE (dsld-adim-temp-ent
                            (list '(0 . "LINE") '(62 . 3)
                                  (cons 10 (list xScan ymin 0.0))
                                  (cons 11 (list xScan ymax 0.0)))))
              (dsld-adim-diag-axis scanE 1 "VERTICAL follow line (rear-to-front)" f)))
          (close f)
          (dsld-adim-msg (strcat "report written: " path))))))
  (dsld-adim-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; ADIMHELP
;;-----------------------------------------------------------------------;;

(defun c:ADIMHELP ()
  (princ (strcat
    "\n[ADIM] v" *DSLD-ADIM-VERSION* " - DSLD Auto Wall Dimensioner"
    "\n  ADIM        window the plan, then CLICK to drop follow lines"
    "\n              (as many as you need), Space = switch horizontal/"
    "\n              vertical, Enter = done.  A chain string lands ON"
    "\n              each line - one stud point per wall (the justified"
    "\n              face, DSLD standard).  Walls in overlaid construct"
    "\n              xrefs (int/ext) are picked up too.  DISCARD pass:"
    "\n              the follow line splits into segments at the studs -"
    "\n              click the segments you don't want dims on (click"
    "\n              again to unmark), Space = vertical, Enter deletes."
    "\n  ADIMROOM    click inside a room -> one dim across that room"
    "\n              between its bracketing stud points, right through"
    "\n              the click.  Space = vertical, Enter = done."
    "\n  ADIMLAYERS  pick sample entities to limit which layers get dims"
    "\n              (default: *A-WALL* only).  Enter clears the filter."
    "\n  ADIMDIAG    census of what a follow line actually crosses ->"
    "\n              ADIMDIAG-report.txt next to the DWG."
    "\n  Dims go on " *DSLD-ADIM-DIM-LAYER* " in the "
                     *DSLD-ADIM-DIMSTYLE* " style."
    "\n  Config lives at the top of ADIM.lsp."))
  (princ))

;;-----------------------------------------------------------------------;;
(princ (strcat "\n[ADIM] v" *DSLD-ADIM-VERSION*
               " loaded.  ADIM = auto dim, ADIMROOM = room dim, "
               "ADIMDIAG = census, ADIMHELP = help."))
(princ)
