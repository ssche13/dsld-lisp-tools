;;;-----------------------------------------------------------------------;;;
;;; ROOF-PITCH-RAFTERS.LSP - DSLD Auto Rafter & Pitch Length Generator
;;;
;;; Command:    RPR  (Roof Pitch Rafters)
;;;
;;; Workflow:   1. User windows around the roof structure to isolate it.
;;;             2. Routine finds N/12 pitch text inside the window.
;;;             3. Each pitch text seeds a closed region via _.BPOLY
;;;                (with a 3" gap tolerance for misaligned corners).
;;;             4. Per region: rafters drawn 24" o.c. perpendicular to
;;;                the longest edge, labeled with on-pitch length, and
;;;                the region is filled with a color-coded SOLID hatch
;;;                keyed to pitch.
;;;
;;; Output layers (auto-created from the source layer + "SSS" suffix):
;;;             A-RoofSSS         rafter lines
;;;             A-Anno-NoteSSS    on-pitch length labels
;;;             A-Roof-PattSSS    color fill hatches
;;;
;;; Compatibility: AutoCAD + BricsCAD (AutoLISP / VL-LISP via vl-load-com).
;;;-----------------------------------------------------------------------;;;

(vl-load-com)

;;-- User-tunable defaults (edit here) ----------------------------------;;
;; The heavy outer roof outlines on DSLD plans live on A-Elev-050-Wide
;; (verified on the real Timsbury roof: without it, 4 edge regions lose
;; their boundary), so it is part of the standard trace set.
(setq *DSLD-RPR-ROOF-LAYERS*    '("A-Roof" "A-Roof-Hidd" "A-Elev-050-Wide"))
;; STRICT-LAYERS mode (v1.9.10): T = trace against ONLY the layers
;; listed above -- no window discovery.  Deterministic scans on
;; standardized DSLD drawings: stray solid lines on odd layers ("0",
;; xref layers, one-off layers the noise patterns don't recognize)
;; can never become region boundaries.  nil = discover roof-structure
;; layers inside the scan window (the default, for non-DSLD drawings
;; whose roof layers are unknown).
(setq *DSLD-RPR-STRICT-LAYERS*  T)
(setq *DSLD-RPR-PITCH-LAYER*    "A-Anno-Note")
(setq *DSLD-RPR-RAFTER-LAYER*   "A-RoofSSS")
(setq *DSLD-RPR-POLY-LAYER*     "A-Roof-OtlnSSS")  ; polygon outlines
                                                    ; (separate from rafter lines)
(setq *DSLD-RPR-LABEL-LAYER*    "A-Anno-NoteSSS")
(setq *DSLD-RPR-FILL-LAYER*     "A-Roof-PattSSS")
(setq *DSLD-RPR-PITCH-LBL-LAYER* "A-Anno-PitchSSS")  ; pitch verification text
(setq *DSLD-RPR-OVERLAP-LAYER*  "A-Wall-OvrlapSSS")  ; overlap-flag polylines
                                                     ; (separate from polygon outlines)
(setq *DSLD-RPR-CHART-LAYER*    "A-Anno-ChartSSS")   ; count chart text
(setq *DSLD-RPR-DEFAULT-OC*     24.0)        ; rafter spacing in inches
;; Bell detection - a "bell" is a row of 4+ identical short rafters along
;; the drip edge.  We DO NOT discard isolated short rafters (cut rafters
;; at a hip apex are legitimate).  A short segment is excluded only if it
;; lines up with 3+ other short segments of similar length.
(setq *DSLD-RPR-BELL-MAX-LEN*   24.0)        ; "short" threshold (in.)
(setq *DSLD-RPR-BELL-RUN-MIN*   4)           ; min consecutive to be a bell
(setq *DSLD-RPR-BELL-MID-TOL*   12.0)        ; midpoint alignment tol (in.)
(setq *DSLD-RPR-BELL-LEN-TOL*   6.0)         ; length similarity tol (in.)
;; H/R/V edge-pairing tolerance (v1.9.11).  Two regions' edges must be
;; collinear within this to earn a shared-edge callout.  Deliberately
;; LOOSER than GAP-TOL: grip-nudging one region's vertex separates its
;; edge from the untouched neighbor, and at 3" a small nudge silently
;; killed the callout on the next refresh.
(setq *DSLD-RPR-EDGE-PAIR-TOL* 6.0)
;; Vertex-weld tolerance (v1.9.15).  Regions are WELDED along the same
;; relation that earns an H/R/V callout, so dragging a vertex can never
;; separate two regions that were paired -- if it could, the callout
;; would die on the very next refresh.  Keep this equal to
;; *DSLD-RPR-EDGE-PAIR-TOL*; making it smaller re-opens that hole.
(setq *DSLD-RPR-WELD-TOL*      6.0)
(setq *DSLD-RPR-GAP-TOL*        3.0)         ; BPOLY gap tolerance, inches (escalates on retry)
(setq *DSLD-RPR-LABEL-HEIGHT*   6.0)         ; text height for length labels
(setq *DSLD-RPR-PITCH-LBL-MULT*    2.0)      ; pitch label is 2x rafter label size
(setq *DSLD-RPR-CALLOUT-TEXT-MULT* 0.85)     ; hip/valley/ridge text size mult
(setq *DSLD-RPR-CALLOUT-RADIUS-MULT* 1.15)   ; bubble radius = mult x callout text size
(setq *DSLD-RPR-OVERLAP-COLOR*  2)            ; AutoCAD color index for overlapping
                                              ; polygon outlines (2 = yellow)
(setq *DSLD-RPR-OVERLAP-LWT*    50)           ; lineweight for overlapping polys
                                              ; (50 = 0.50 mm)
(setq *DSLD-RPR-EPS*            0.0013)      ; ~1/64", float-noise tolerance
(setq *DSLD-RPR-FILL-TRANSP*    80)          ; hatch transparency 0-90
(setq *DSLD-RPR-PITCH-RE*       "^[ \t]*\\([0-9]+\\(\\.[0-9]+\\)?\\)[ \t]*/[ \t]*12[ \t]*$")

;; Per-polygon outline color cycle.  Each region's polygon outline gets a
;; distinct color so adjacent regions are visually distinguishable along
;; their shared edges.  Avoid colors used elsewhere: 2 = overlap yellow,
;; 7 = bylayer-ish, and the pitch-fill colors above.
(setq *DSLD-RPR-OUTLINE-COLORS*
  '(150 30 80 180 230 90 220 40 130 200 170 50 110 60 190 250 100 170))
(setq *DSLD-RPR-OUTLINE-CLR-IDX* 0)          ; cycles, reset by c:RPR pass 1
(setq *DSLD-RPR-GRP-IDX*         0)          ; monotonic group-name counter

;; Bind polygon + fill hatch into a Group so click-selects-both works?
;; Off by default in v1.7.7 -- AutoCAD Architecture won't let you grip-
;; edit polygon vertices while the polygon is a group member, even with
;; PICKSTYLE bit 0 cleared.  Set this to T in your acaddoc.lsp if you're
;; on BricsCAD and want the click-selects-both behavior back.
(setq *DSLD-RPR-USE-GROUPS*      nil)

;;-- Auto-update from GitHub --------------------------------------------;;
;; Bump *DSLD-RPR-VERSION* whenever a meaningful change is pushed so
;; users can see in the load message what they have.  Auto-update on
;; file load is gated by *DSLD-RPR-AUTOUPDATE* (default T); set it to
;; nil in your acaddoc.lsp to disable.  c:RPRUPDATE forces a manual
;; check at any time.
(setq *DSLD-RPR-VERSION*    "1.9.16")
(setq *DSLD-RPR-AUTOUPDATE* T)
(setq *DSLD-RPR-GITHUB-RAW-URL*
  "https://raw.githubusercontent.com/ssche13/dsld-lisp-tools/main/DSLD-Tools.bundle/Contents/roof-pitch-rafters.lsp")

;; Text style for labels.  In DSLD templates the "Standard" style is already
;; mapped to LBRITE.TTF (Lucida Bright, width 0.925).  In any other drawing,
;; we create "DSLD-LB" so the routine produces matching DSLD text regardless.
(setq *DSLD-RPR-TEXT-STYLE*     "DSLD-LB")
(setq *DSLD-RPR-TEXT-FONT*      "LBRITE.TTF")
(setq *DSLD-RPR-TEXT-WIDTH*     0.925)

;; Pitch -> AutoCAD Color Index. Unmapped pitches use a generated color.
(setq *DSLD-RPR-COLOR-MAP*
  '((3  . 141) (4  . 151) (5  . 121) (6  .  91) (7  .  51)
    (8  .  31) (9  .  21) (10 .  11) (11 . 191) (12 .   1)
    (14 . 211) (16 . 231)))

;;-- Memory of last user inputs -----------------------------------------;;
(or *DSLD-RPR-LAST-OC*   (setq *DSLD-RPR-LAST-OC*   *DSLD-RPR-DEFAULT-OC*))
(or *DSLD-RPR-LAST-BBOX* (setq *DSLD-RPR-LAST-BBOX* nil))

;; Multi-scan bookkeeping (v1.7.7+).  Each c:RPR run allocates or
;; reuses a scan slot.  Each slot's polygon outlines live on their own
;; layer named "RPR<N>", and the slot remembers its bbox + spacing so
;; the reactor and RPRREFRESH can regenerate the RIGHT scan when the
;; user grip-edits one of its polygons.
;;
;; *DSLD-RPR-SCAN-COUNTER* -- monotonic; the next scan slot ID
;; *DSLD-RPR-SCANS*        -- list of (scan-id p1 p2 oc poly-layer)
(or *DSLD-RPR-SCAN-COUNTER* (setq *DSLD-RPR-SCAN-COUNTER* 0))
(or *DSLD-RPR-SCANS*        (setq *DSLD-RPR-SCANS*        nil))

;; Reentrancy guard: T while a reactor-driven (or manual) refresh is
;; running, so nothing on the refresh path re-triggers a refresh and
;; group binding (a command) is never attempted from reactor context.
(setq *DSLD-RPR-REFRESHING* nil)

;; Restore-state stash for the shared *error* handler (v1.8.0).  Each
;; command records what it changed here at entry; dsld-rpr-cleanup
;; puts everything back on normal exit AND on Esc/error.
(setq *DSLD-RPR-CLEANUP* nil)

;;-----------------------------------------------------------------------;;
;; Helpers
;;-----------------------------------------------------------------------;;

(defun dsld-rpr-msg (s) (princ (strcat "\n[RPR] " s)))

;; Flushed breadcrumb logging (v1.9.9).  Set *DSLD-RPR-DEBUG-LOG* to a
;; file path (test scripts / field seats) and the scan pipeline writes
;; one line per step -- open/append/close per line so the trail
;; survives a hang or crash.  nil (default) = no-op.
(defun dsld-rpr-dbg (s / f)
  (if *DSLD-RPR-DEBUG-LOG*
    (progn
      (setq f (open *DSLD-RPR-DEBUG-LOG* "a"))
      (if f (progn (princ (strcat s "\n") f) (close f))))))

;; True if a layer name matches a known "non-roof" pattern (walls,
;; dimensions, annotations, doors, glazing, MEP, etc.).  Used to decide
;; which layers should be turned OFF during BPOLY tracing so they don't
;; contribute spurious boundaries.  Layers not on this list stay
;; visible -- including unknown / custom names like "0", "Bldg-Otln",
;; "Layer1", because we'd rather risk a false positive boundary than
;; miss roof structure entirely.
(defun dsld-rpr-is-noise-layer (lay / up)
  (setq up (strcase lay))
  (or (vl-string-search "WALL"     up)
      (vl-string-search "DOOR"     up)
      (vl-string-search "GLAZ"     up)
      (vl-string-search "WIND"     up)   ; A-Wind, Window
      (vl-string-search "DETL"     up)
      (vl-string-search "ANNO"     up)   ; covers A-Anno-Note (pitch tags
                                          ; live here; we do NOT want
                                          ; their geometry in BPOLY)
      (vl-string-search "DIM"      up)
      (vl-string-search "FLOR"     up)
      (vl-string-search "ELEC"     up)
      (vl-string-search "MECH"     up)
      (vl-string-search "PLUM"     up)
      (vl-string-search "HVAC"     up)
      (vl-string-search "DEFP"     up)   ; Defpoints
      (vl-string-search "FURN"     up)
      (vl-string-search "EQPM"     up)
      (vl-string-search "CABS"     up)
      (vl-string-search "APPL"     up)))

;; Convert a selection set to a list of entity names.  Avoids ssnamex
;; whose return format differs between AutoCAD and BricsCAD (and
;; between selection methods within a single CAD), which has bitten
;; this codebase before.
(defun dsld-rpr-ss->list (ss / n i result)
  (if ss
    (progn
      (setq n (sslength ss) i 0 result '())
      (while (< i n)
        (setq result (cons (ssname ss i) result))
        (setq i (1+ i)))
      (reverse result))))

;;-----------------------------------------------------------------------;;
;; Cleanup + *error* infrastructure (v1.8.0)
;;-----------------------------------------------------------------------;;
;; Every interactive command stashes what it changed via
;; dsld-rpr-stash, then binds *error* to dsld-rpr-cmd-error (declared
;; as a LOCAL so the previous handler auto-restores on exit).  Esc,
;; (exit), and hard errors all route through the handler, which
;; restores sysvars, un-isolates layers, and -- critically -- moves
;; any dashed linework back off the hidden _RPR_HIDE_TMP layer.

(defun dsld-rpr-stash (key val)
  (setq *DSLD-RPR-CLEANUP*
        (cons (cons key val)
              (vl-remove-if '(lambda (kv) (eq (car kv) key))
                            *DSLD-RPR-CLEANUP*))))

(defun dsld-rpr-cleanup ( / kv)
  (foreach kv *DSLD-RPR-CLEANUP*
    (vl-catch-all-apply
      '(lambda ()
         (cond
           ((eq (car kv) 'cmdecho)  (setvar "CMDECHO"  (cdr kv)))
           ((eq (car kv) 'clayer)   (setvar "CLAYER"   (cdr kv)))
           ((eq (car kv) 'osmode)   (setvar "OSMODE"   (cdr kv)))
           ((eq (car kv) 'hpgaptol) (setvar "HPGAPTOL" (cdr kv)))
           ((eq (car kv) 'off-list) (dsld-rpr-restore-layers (cdr kv)))
           ;; v1.9.15: the missed-area capture blinds BPOLY to RPR's own
           ;; output by switching those layers off around each trace.  An
           ;; Esc mid-loop used to leave them off, so the rafters and
           ;; H/R/V callouts looked like they had vanished.
           ((eq (car kv) 'md-off)   (dsld-rpr-set-layers-on (cdr kv) :vlax-true))
           ((eq (car kv) 'md-iso)   (dsld-rpr-restore-layers (cdr kv)))
           ((eq (car kv) 'hidden)   (dsld-rpr-restore-visible (cdr kv)))))))
  (setq *DSLD-RPR-CLEANUP* nil))

;; Shared *error* body.  Commands bind:  (setq *error* dsld-rpr-cmd-error)
;; with *error* in their local-variable list.
(defun dsld-rpr-cmd-error (msg)
  (dsld-rpr-cleanup)
  (if (and msg
           (not (member (strcase msg T)
                        '("function cancelled" "quit / exit abort"
                          "console break"))))
    (princ (strcat "\n[RPR] Error: " msg)))
  (princ))

;;-----------------------------------------------------------------------;;
;; View-independent bbox selection (v1.8.0)
;;-----------------------------------------------------------------------;;
;; ssget "_C"/"_W" only see entities in the CURRENT VIEW -- a refresh
;; fired while the user is zoomed elsewhere would miss everything.
;; These use database-wide ssget "_X" plus a coordinate test, so they
;; work regardless of zoom state (reactor-safe).

;; Representative point of an entity for bbox-containment testing.
;; HATCH is special: its first group-10 is the ELEVATION point, always
;; (0,0,0) for our entmade fills -- use the real bbox center instead.
(defun dsld-rpr-ent-ref-pt (e / d typ p1 p2)
  (setq d   (entget e))
  (setq typ (cdr (assoc 0 d)))
  (cond
    ((= typ "LINE")
     (setq p1 (cdr (assoc 10 d)) p2 (cdr (assoc 11 d)))
     (list (/ (+ (car p1) (car p2)) 2.0)
           (/ (+ (cadr p1) (cadr p2)) 2.0)))
    ((= typ "LWPOLYLINE")
     (cdr (assoc 10 d)))               ; first vertex
    ((= typ "HATCH")
     (setq p1 (vl-catch-all-apply 'dsld-rpr-bbox-center-ent (list e)))
     (if (vl-catch-all-error-p p1) nil p1))
    (T (cdr (assoc 10 d)))))           ; TEXT / CIRCLE insertion

;; All entities of dxf-type(s) on layer(s) whose reference point falls
;; inside bbox p1-p2 (+tol margin).  Type/layer strings may contain
;; commas / wildcards as in any ssget filter.
(defun dsld-rpr-ents-in-bbox (etype elayer p1 p2 tol / ss out pt
                               xmin xmax ymin ymax)
  (setq xmin (- (min (car  p1) (car  p2)) tol)
        xmax (+ (max (car  p1) (car  p2)) tol)
        ymin (- (min (cadr p1) (cadr p2)) tol)
        ymax (+ (max (cadr p1) (cadr p2)) tol))
  (setq ss (ssget "_X" (list (cons 0 etype) (cons 8 elayer))))
  (setq out '())
  (foreach e (dsld-rpr-ss->list ss)
    (setq pt (dsld-rpr-ent-ref-pt e))
    (if (and pt
             (>= (car  pt) xmin) (<= (car  pt) xmax)
             (>= (cadr pt) ymin) (<= (cadr pt) ymax))
      (setq out (cons e out))))
  (reverse out))

;; Scan polygons whose EXTENTS touch a window (v1.9.15).  Region fetch
;; must not use dsld-rpr-ents-in-bbox: that tests one reference point --
;; for an LWPOLYLINE its FIRST VERTEX -- so grip-dragging that single
;; corner past the scan window silently dropped the entire region from
;; the refresh, wiping its rafters and drawing no replacements.
(defun dsld-rpr-polys-touching-bbox (layer p1 p2 / ss out bb lo hi
                                            xmin xmax ymin ymax)
  (setq xmin (min (car  p1) (car  p2)) xmax (max (car  p1) (car  p2))
        ymin (min (cadr p1) (cadr p2)) ymax (max (cadr p1) (cadr p2)))
  (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE") (cons 8 layer))))
  (setq out '())
  (foreach e (dsld-rpr-ss->list ss)
    (setq bb (vl-catch-all-apply 'dsld-rpr-poly-bbox (list e)))
    (cond
      ((vl-catch-all-error-p bb) nil)
      (T
       (setq lo (car bb) hi (cadr bb))
       (if (and (<= (car  lo) xmax) (>= (car  hi) xmin)
                (<= (cadr lo) ymax) (>= (cadr hi) ymin))
         (setq out (cons e out))))))
  (reverse out))

;;-----------------------------------------------------------------------;;
;; Manual-entity protection (v1.8.0)
;;-----------------------------------------------------------------------;;
;; RPRADD rafters and RPRCALCPITCH labels are user work -- refreshes
;; must NOT delete them.  They carry DSLD_RPR_MANUAL xdata; every wipe
;; skips tagged entities.

(defun dsld-rpr-tag-manual (e / data)
  (if e
    (progn
      (regapp "DSLD_RPR_MANUAL")
      (setq data (entget e))
      (entmod (append data
                      (list (list -3 (list "DSLD_RPR_MANUAL"
                                           (cons 1070 1)))))))))

(defun dsld-rpr-manual-p (e)
  (and (assoc -3 (entget e '("DSLD_RPR_MANUAL"))) T))

;;-----------------------------------------------------------------------;;
;; Multi-scan helpers (v1.7.7+)
;;-----------------------------------------------------------------------;;

;; Layer name for a given scan ID.  "RPR1", "RPR2", etc.
(defun dsld-rpr-scan-layer (scan-id)
  (strcat "RPR" (itoa scan-id)))

;; Read scan-id from a polygon by parsing its layer name.  Returns the
;; integer N if layer matches "RPR<N>" pattern, else nil.
(defun dsld-rpr-scan-id-from-layer (lay / rest)
  (cond
    ((not lay) nil)
    ((and (= (strcase (substr lay 1 3)) "RPR")
          (setq rest (substr lay 4))
          (> (strlen rest) 0)
          (distof rest))
     (fix (distof rest)))))

;; Look up a scan tuple by ID from *DSLD-RPR-SCANS*.
;; Tuple is (scan-id p1 p2 oc poly-layer).
(defun dsld-rpr-find-scan (scan-id / hit)
  (foreach s *DSLD-RPR-SCANS*
    (if (= (car s) scan-id) (setq hit s)))
  hit)

;; True if 2D point pt is inside the axis-aligned bbox (p1 p2).
(defun dsld-rpr-pt-in-bbox (pt p1 p2)
  (and (>= (car  pt) (min (car  p1) (car  p2)))
       (<= (car  pt) (max (car  p1) (car  p2)))
       (>= (cadr pt) (min (cadr p1) (cadr p2)))
       (<= (cadr pt) (max (cadr p1) (cadr p2)))))

;; Given a new (p1 p2) bbox, return an existing scan whose bbox center
;; is inside the new bbox (or whose center contains the new bbox's
;; center).  Used by c:RPR to decide "reuse this scan slot" vs "new".
(defun dsld-rpr-find-overlapping-scan (p1 p2 / center hit sp1 sp2 s-center)
  (setq center (list (/ (+ (car  p1) (car  p2)) 2.0)
                     (/ (+ (cadr p1) (cadr p2)) 2.0)
                     0.0))
  (foreach s *DSLD-RPR-SCANS*
    (setq sp1 (nth 1 s))
    (setq sp2 (nth 2 s))
    (setq s-center (list (/ (+ (car  sp1) (car  sp2)) 2.0)
                         (/ (+ (cadr sp1) (cadr sp2)) 2.0)
                         0.0))
    (if (and (not hit)
             (or (dsld-rpr-pt-in-bbox center   sp1 sp2)
                 (dsld-rpr-pt-in-bbox s-center p1  p2)))
      (setq hit s)))
  hit)

;; Register a scan slot (create OR update existing).  On update the
;; new bbox is UNIONED with the previous one, so re-scanning a smaller
;; window inside a big roof doesn't orphan polygons outside the new
;; window (they'd stop refreshing otherwise).  Returns the final tuple
;; (scan-id p1 p2 oc poly-layer).
(defun dsld-rpr-register-scan (scan-id p1 p2 oc / lay old op1 op2
                                nx1 ny1 nx2 ny2 tuple)
  (setq lay (dsld-rpr-scan-layer scan-id))
  (setq nx1 (min (car p1) (car p2))   ny1 (min (cadr p1) (cadr p2))
        nx2 (max (car p1) (car p2))   ny2 (max (cadr p1) (cadr p2)))
  (setq old (dsld-rpr-find-scan scan-id))
  (cond
    (old
     (setq op1 (nth 1 old) op2 (nth 2 old))
     (setq nx1 (min nx1 (car op1) (car op2))
           ny1 (min ny1 (cadr op1) (cadr op2))
           nx2 (max nx2 (car op1) (car op2))
           ny2 (max ny2 (cadr op1) (cadr op2)))))
  (setq tuple (list scan-id
                    (list nx1 ny1 0.0)
                    (list nx2 ny2 0.0)
                    oc lay))
  (setq *DSLD-RPR-SCANS*
        (cons tuple
              (vl-remove-if
                '(lambda (s) (= (car s) scan-id))
                *DSLD-RPR-SCANS*)))
  tuple)

;; Drop a scan slot from the tracking list (does NOT delete geometry).
(defun dsld-rpr-forget-scan (scan-id)
  (setq *DSLD-RPR-SCANS*
        (vl-remove-if '(lambda (s) (= (car s) scan-id))
                      *DSLD-RPR-SCANS*)))

;; Rediscover scan slots after a CAD restart (v1.8.0).  The registry
;; lives only in LISP memory, but the RPR<N> layers + their tagged
;; polygons persist in the DWG.  Walk the layer table for RPR<N>
;; names, rebuild each slot's bbox from the union of its polygons'
;; vertices (+margin for rafter labels / callouts hanging past
;; edges), and bump the counter past the highest N found.  No-op for
;; slots already registered.  Call before any operation that needs
;; the registry (RPR / RPRREFRESH / RPRRESULT / RPRSHOW / reactor).
(defun dsld-rpr-rediscover-scans ( / lay-rec lay-name sid ss verts
                                    xmin ymin xmax ymax margin v e)
  (setq lay-rec (tblnext "LAYER" T))
  (while lay-rec
    (setq lay-name (cdr (assoc 2 lay-rec)))
    (setq sid (dsld-rpr-scan-id-from-layer lay-name))
    (cond
      ((and sid (not (dsld-rpr-find-scan sid)))
       (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE")
                                  (cons 8 lay-name))))
       (cond
         (ss
          (setq xmin nil)
          (foreach e (dsld-rpr-ss->list ss)
            (foreach v (dsld-rpr-poly-vertices e)
              (cond
                ((not xmin)
                 (setq xmin (car v) xmax (car v)
                       ymin (cadr v) ymax (cadr v)))
                (T
                 (setq xmin (min xmin (car v)) xmax (max xmax (car v))
                       ymin (min ymin (cadr v)) ymax (max ymax (cadr v)))))))
          (cond
            (xmin
             (setq margin (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
             (dsld-rpr-register-scan
               sid
               (list (- xmin margin) (- ymin margin) 0.0)
               (list (+ xmax margin) (+ ymax margin) 0.0)
               *DSLD-RPR-LAST-OC*)
             (if (> sid *DSLD-RPR-SCAN-COUNTER*)
               (setq *DSLD-RPR-SCAN-COUNTER* sid))))))))
    (setq lay-rec (tblnext "LAYER"))))

;; Every traced polygon on any registered scan layer plus the current
;; poly layer.  Used to detect a missed-area trace that merely
;; re-traced an existing region.
(defun dsld-rpr-all-scan-polys ( / lays out ss l e)
  (setq lays (list *DSLD-RPR-POLY-LAYER*))
  (foreach s *DSLD-RPR-SCANS*
    (if (not (member (nth 4 s) lays))
      (setq lays (cons (nth 4 s) lays))))
  (setq out '())
  (foreach l lays
    (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE") (cons 8 l))))
    (foreach e (dsld-rpr-ss->list ss)
      (setq out (cons e out))))
  out)

;; Fraction of SMALL's interior that lies inside BIG, estimated by
;; sampling an 8x8 lattice over SMALL's bbox and keeping the points
;; interior to SMALL.  Cheap, convexity-independent.
;; Lattice fractions are OFFSET DIFFERENTLY per axis (v1.9.13): equal
;; x/y fractions land samples exactly ON a corner-to-corner diagonal
;; (two triangles sharing a hypotenuse false-positived as overlapping).
(defun dsld-rpr-overlap-frac (small big / bb lo hi w h i j pt
                               n-in n-both)
  (setq bb (dsld-rpr-poly-bbox small))
  (setq lo (car bb) hi (cadr bb))
  (setq w (- (car hi) (car lo))
        h (- (cadr hi) (cadr lo)))
  (setq n-in 0 n-both 0 i 1)
  (while (<= i 8)
    (setq j 1)
    (while (<= j 8)
      (setq pt (list (+ (car lo)  (* w (/ (- i 0.29) 8.42)))
                     (+ (cadr lo) (* h (/ (- j 0.71) 8.58)))))
      (if (dsld-rpr-pt-in-poly pt small)
        (progn
          (setq n-in (1+ n-in))
          (if (dsld-rpr-pt-in-poly pt big) (setq n-both (1+ n-both)))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  (if (> n-in 0) (/ (float n-both) n-in) 0.0))

;; The existing polygon that new-region duplicates, or nil.  Duplicate
;; means areas within 15% AND genuine interior overlap.
;;
;; v1.9.6 used mutual bbox-center containment, which FAILS on triangular
;; / non-convex slopes whose bounding-box center falls OUTSIDE the
;; polygon -- exactly the real-roof case where two pitch callouts (e.g.
;; 8/12 and 12/12) land in one BPOLY-traceable area and get traced into
;; two identical regions.  The bbox-center test never matched, so both
;; survived and drew rafters in different directions -> crossing rafters.
;; dsld-rpr-regions-overlap-p samples true interior points, so it
;; catches the overlap regardless of convexity.
;; v1.9.8 second rule: the SAME slope re-traced from another callout can
;; flood a somewhat DIFFERENT extent (e.g. across an untraced band), so
;; areas differ by more than 15% -- on the real Timsbury roof one slope
;; survived as THREE traces, each drawing its own 24" rafter grid at a
;; slightly different origin (doubled stubs, sub-inch grid offsets,
;; inflated takeoff).  A trace is also a duplicate when it mostly sits
;; inside an existing region (>=60% interior overlap) AND is at least
;; half its size.  Genuinely nested sub-areas (dormer strips) stay legal:
;; they are far smaller than half the parent.
(defun dsld-rpr-region-duplicate-of (new-region polys / na dup pa small big)
  (setq na (dsld-rpr-poly-area-flat new-region))
  (foreach p polys
    (if (and (not dup)
             (not (eq p new-region))
             (setq pa (dsld-rpr-poly-area-flat p))
             (> na 0.0) (> pa 0.0))
      (cond
        ;; rule 1: near-equal areas + interiors overlap
        ((and (< (abs (- na pa)) (* 0.15 (max na pa)))
              (dsld-rpr-regions-overlap-p new-region p))
         (setq dup p))
        ;; rule 2: re-trace of the same slope with a different flood
        ;; extent -- mostly-contained and at least half the size
        ((and (>= (min na pa) (* 0.5 (max na pa)))
              (progn
                (setq small (if (<= na pa) new-region p))
                (setq big   (if (<= na pa) p new-region))
                (>= (dsld-rpr-overlap-frac small big) 0.6)))
         (setq dup p)))))
  dup)

;; A missed-area trace is BAD when it flooded past any plausible region
;; (bigger than the same cap the main pick loop uses) or when it merely
;; re-traced a region we already have.
(defun dsld-rpr-missed-region-bad-p (region max-area)
  (or (> (dsld-rpr-region-bbox-area region) max-area)
      (and (dsld-rpr-region-duplicate-of region (dsld-rpr-all-scan-polys)) T)))

;;-----------------------------------------------------------------------;;
;; Region-boolean orphan rescue (v1.9.11)
;;-----------------------------------------------------------------------;;
;; A slope whose boundary is partly dashed traces (dashes hidden) as a
;; region that OVERLAPS already-kept neighbors, so dedupe kills it and
;; the dashed-visible retry fragments on interior framing lines.  But
;; flood MINUS the kept neighbors IS the missing slope -- and the CAD's
;; own REGION booleans compute that robustly.  ActiveX only (needs the
;; document object -- present in every real session; headless core
;; console simply skips, callout stays reported as orphan).

;; Chain loose (p1 p2) segments into closed loops by endpoint matching.
;; Returns a list of vertex-lists.
(defun dsld-rpr-chain-segs->loops (segs / tol loops cur pt seg found rest)
  (setq tol 0.05 loops '())
  (while segs
    (setq seg  (car segs)
          segs (cdr segs))
    (setq cur (list (cadr seg) (car seg)))   ; walking from (cadr) end
    (setq found T)
    (while found
      (setq pt (car cur) found nil rest '())
      (foreach s segs
        (cond
          (found (setq rest (cons s rest)))
          ((< (distance pt (car s)) tol)
           (setq cur (cons (cadr s) cur) found T))
          ((< (distance pt (cadr s)) tol)
           (setq cur (cons (car s) cur) found T))
          (T (setq rest (cons s rest)))))
      (if found (setq segs (reverse rest))))
    ;; closed if first ~= last; drop the duplicate closing vertex
    (if (and (> (length cur) 3)
             (< (distance (car cur) (last cur)) (* tol 4.0)))
      (setq loops (cons (cdr cur) loops))))
  loops)

;; flood-poly MINUS kept-polys via ActiveX region booleans; returns a
;; new closed LWPOLYLINE (on lay) for the result loop containing
;; pick-pt, or nil.  All temp objects cleaned up.
(defun dsld-rpr-region-subtract-capture (flood-poly kept-polys pick-pt lay
                                          / doc space mkreg fr kr e segs
                                          lines loops lp cand best err)
  (setq err
    (vl-catch-all-apply
      '(lambda ( / regs)
         (setq doc   (vla-get-activedocument (vlax-get-acad-object)))
         (setq space (vla-get-modelspace doc))
         ;; region from a closed LWPOLYLINE ename (AddRegion returns a list)
         (defun mkreg (pl / o r)
           (setq o (vlax-ename->vla-object pl))
           (setq r (vl-catch-all-apply
                     '(lambda () (vlax-invoke space 'AddRegion (list o)))))
           (cond
             ((vl-catch-all-error-p r)
              (dsld-rpr-dbg (strcat "      AddRegion ERR: "
                                    (vl-catch-all-error-message r)))
              nil)
             ((and r (car r)) (car r))
             (T (dsld-rpr-dbg "      AddRegion returned empty") nil)))
         (setq fr (mkreg flood-poly))
         (cond ((not fr)
                (dsld-rpr-dbg "      exit: flood region failed") (exit)))
         (foreach kp kept-polys
           (setq kr (mkreg kp))
           ;; acSubtraction = 2; the tool region is consumed by Boolean
           (if kr
             (progn
               (setq e (vl-catch-all-apply
                         '(lambda () (vla-Boolean fr 2 kr))))
               (if (vl-catch-all-error-p e)
                 (dsld-rpr-dbg (strcat "      Boolean ERR: "
                                       (vl-catch-all-error-message e)))))))
         ;; empty result?
         (setq e (vl-catch-all-apply '(lambda () (vla-get-Area fr))))
         (cond
           ((vl-catch-all-error-p e)
            (dsld-rpr-dbg "      exit: result area unreadable") (exit))
           ((< e 1.0)
            (dsld-rpr-dbg "      exit: result empty (flood inside kept)")
            (exit))
           (T (dsld-rpr-dbg (strcat "      result area " (rtos e 2 0)))))
         ;; explode to lines, collect endpoints, delete the temps
         (setq lines (vl-catch-all-apply '(lambda () (vlax-invoke fr 'Explode))))
         (cond
           ((vl-catch-all-error-p lines)
            (dsld-rpr-dbg (strcat "      exit: explode ERR: "
                                  (vl-catch-all-error-message lines)))
            (exit)))
         (dsld-rpr-dbg (strcat "      exploded into "
                               (itoa (length lines)) " entities"))
         (setq segs '())
         (foreach ln lines
           (vl-catch-all-apply
             '(lambda ()
                (setq segs (cons (list (vlax-get ln 'StartPoint)
                                       (vlax-get ln 'EndPoint))
                                 segs))
                (vla-delete ln))))
         (vla-delete fr) (setq fr nil)
         ;; chain into loops; keep the loop containing the pick
         (setq loops (dsld-rpr-chain-segs->loops segs))
         (setq best nil)
         (foreach lp loops
           (setq cand (if (not best) (dsld-rpr-make-lwpoly lp lay)))
           (cond
             ((not cand) nil)
             ((dsld-rpr-pt-in-poly pick-pt cand) (setq best cand))
             (T (entdel cand))))
         best)))
  ;; salvage cleanup if we bailed mid-way
  (if (and fr (not (vl-catch-all-error-p
                     (vl-catch-all-apply 'vlax-vla-object->ename (list fr)))))
    (vl-catch-all-apply 'vla-delete (list fr)))
  (cond
    ((vl-catch-all-error-p err)
     (dsld-rpr-dbg (strcat "    subtract-capture ERROR: "
                           (vl-catch-all-error-message err)))
     nil)
    (T err)))

;; Return the effective linetype name of an entity (string).  Honors
;; ByLayer inheritance: if the entity says "ByLayer" we look up the
;; layer's linetype.  Defaults to "Continuous" when nothing is set.
(defun dsld-rpr-entity-linetype (ent / data lt lay layd)
  (setq data (entget ent))
  (setq lt   (cdr (assoc 6 data)))
  (cond
    ((and lt
          (/= (strcase lt) "BYLAYER")
          (/= (strcase lt) "BYBLOCK")
          (/= lt ""))
     lt)
    (T
     (setq lay  (cdr (assoc 8 data)))
     (setq layd (tblsearch "LAYER" lay))
     (if layd (cdr (assoc 6 layd)) "Continuous"))))

;; T if an entity's effective linetype is anything other than
;; Continuous (i.e. DASHED, HIDDEN, CENTER, DASHDOT, etc.).
(defun dsld-rpr-is-non-solid-line (ent / lt)
  (setq lt (strcase (dsld-rpr-entity-linetype ent)))
  (and (/= lt "CONTINUOUS") (/= lt "")))

;; Hide every non-Continuous LINE/LWPOLYLINE/etc. inside the bbox by
;; MOVING them onto a temporary layer that has visibility turned off.
;; Layer-move is more reliable than .Visible=false in AutoCAD
;; Architecture -- ACA's BPOLY sometimes still walks entities marked
;; invisible, but it always skips an entity whose layer is off.
;;
;; Returns a list of (ename . original-layer-name) pairs for restore.
(setq *DSLD-RPR-HIDE-LAYER* "_RPR_HIDE_TMP")

(defun dsld-rpr-hide-non-solid-in-bbox (p1 p2 / ss hidden data orig-layer)
  (dsld-rpr-ensure-layer *DSLD-RPR-HIDE-LAYER* "0")
  (dsld-rpr-set-layers-on (list *DSLD-RPR-HIDE-LAYER*) :vlax-false)
  (setq hidden '())
  (setq ss (ssget "_C" p1 p2
             '((0 . "LINE,LWPOLYLINE,POLYLINE,ARC,CIRCLE,SPLINE,ELLIPSE"))))
  (cond
    (ss
     (foreach e (dsld-rpr-ss->list ss)
       (cond
         ((and (dsld-rpr-is-non-solid-line e)
               ;; never re-hide an entity already on the temp layer --
               ;; that would record _RPR_HIDE_TMP as its "original"
               ;; layer and strand it there on restore
               (/= (strcase (cdr (assoc 8 (entget e))))
                   (strcase *DSLD-RPR-HIDE-LAYER*)))
          (setq data       (entget e))
          (setq orig-layer (cdr (assoc 8 data)))
          (vl-catch-all-apply
            '(lambda ()
               (entmod (subst (cons 8 *DSLD-RPR-HIDE-LAYER*)
                              (assoc 8 data)
                              data))))
          (setq hidden (cons (cons e orig-layer) hidden)))))))
  hidden)

;; Move each entity in the hidden list back to its original layer.
;; Skips entities that have since been deleted.
(defun dsld-rpr-restore-visible (hidden / pair data)
  (foreach pair hidden
    (if (entget (car pair))
      (vl-catch-all-apply
        '(lambda ()
           (setq data (entget (car pair)))
           (entmod (subst (cons 8 (cdr pair)) (assoc 8 data) data)))))))

;; Selective restore (v1.9.13): bring back ONLY the hidden dashed
;; entities that run DIAGONALLY (5..85 degrees off cardinal).  On DSLD
;; plans the valley/hip boundaries are diagonal dashed lines while the
;; below-roof framing clutter is cardinal -- so this makes multi-slope
;; zones traceable WITHOUT fragmenting on framing.  Returns the subset
;; of HIDDEN pairs actually restored (for selective re-hide).
(defun dsld-rpr-restore-diagonals (hidden / out pair e ed p1 p2 deg)
  (setq out '())
  (foreach pair hidden
    (setq e (car pair))
    (cond
      ((not (entget e)) nil)
      (T
       (setq ed (entget e))
       (cond
         ((= (cdr (assoc 0 ed)) "LINE")
          (setq p1 (cdr (assoc 10 ed)) p2 (cdr (assoc 11 ed)))
          (setq deg (* 180.0 (/ (rem (abs (angle p1 p2)) pi) pi)))
          (if (> deg 90.0) (setq deg (- 180.0 deg)))
          (if (and (> deg 5.0) (< deg 85.0))
            (progn
              (entmod (subst (cons 8 (cdr pair)) (assoc 8 ed) ed))
              (setq out (cons pair out)))))))))
  out)

;; Move a set of restored pairs back onto the hidden temp layer.
(defun dsld-rpr-rehide-pairs (pairs / pair ed)
  (foreach pair pairs
    (cond
      ((entget (car pair))
       (setq ed (entget (car pair)))
       (entmod (subst (cons 8 *DSLD-RPR-HIDE-LAYER*)
                      (assoc 8 ed) ed))))))

;; Clamped perpendicular projection of P onto segment A-B (2D).
(defun dsld-rpr-project-to-seg (p a b / dx dy len2 prm)
  (setq dx (- (car b) (car a)) dy (- (cadr b) (cadr a)))
  (setq len2 (+ (* dx dx) (* dy dy)))
  (cond
    ((< len2 1e-9) a)
    (T
     (setq prm (/ (+ (* (- (car p) (car a)) dx)
                     (* (- (cadr p) (cadr a)) dy))
                  len2))
     (if (< prm 0.0) (setq prm 0.0))
     (if (> prm 1.0) (setq prm 1.0))
     (list (+ (car a) (* prm dx)) (+ (cadr a) (* prm dy)) 0.0))))

;; Snap REGION's vertices onto nearby edges of KEPT polygons (v1.9.13).
;; A slope traced against a DASHED boundary sits an inch or three off
;; the neighbor that traced against the parallel SOLID line -- the
;; sliver overlap put a 24"-spaced row of rafter X's along the seam.
;; Snapping the new region's vertices onto the kept edges collapses
;; the seam exactly.  Kept regions stay authoritative.
(defun dsld-rpr-snap-region-to-kept (region kept-polys tol / verts i v
                                      best bp kp kv n j a b pr d)
  (setq verts (dsld-rpr-poly-vertices region) i 0)
  (foreach v verts
    (setq best nil bp nil)
    (foreach kp kept-polys
      (cond
        ((eq kp region) nil)
        ((not (entget kp)) nil)
        ;; only vertices sitting INSIDE the kept region are pulled out
        ;; to its boundary -- that is the seam-overlap case.  Vertices
        ;; near-but-outside (separate structures 5" apart) and deep-
        ;; inside vertices (contained dormer strips) stay untouched.
        ((not (dsld-rpr-pt-in-poly v kp)) nil)
        (T
         (setq kv (dsld-rpr-poly-vertices kp) n (length kv) j 0)
         (while (< j n)
           (setq a (nth j kv) b (nth (rem (1+ j) n) kv))
           (setq pr (dsld-rpr-project-to-seg v a b))
           (setq d (distance v pr))
           (if (and (> d 0.01) (< d tol)
                    (or (not best) (< d best)))
             (progn (setq best d) (setq bp pr)))
           (setq j (1+ j))))))
    (if bp (dsld-rpr-poly-move-vertex region i bp))
    (setq i (1+ i))))

;; Ceiling with epsilon to suppress floating-point noise.
(defun dsld-rpr-ceil (x / f)
  (setq f (fix x))
  (cond
    ((minusp x) f)                              ; only positive lengths used
    ((< (- x f) *DSLD-RPR-EPS*) f)
    (T (1+ f))))

;; The DSLD rounding rule:
;;   x <= 6.0  -> ceil(x) to nearest 1 ft
;;   6 < x <= 8 -> 8
;;   x  > 8.0  -> ceil(x) to next even ft
(defun dsld-rpr-round-len-ft (len-ft / c)
  (cond
    ((<= len-ft (+ 6.0 *DSLD-RPR-EPS*))
     (dsld-rpr-ceil len-ft))
    ((<= len-ft (+ 8.0 *DSLD-RPR-EPS*)) 8)
    (T (setq c (dsld-rpr-ceil len-ft))
       (if (zerop (rem c 2)) c (1+ c)))))

;; Format an integer foot value as a tick string (e.g. 12 -> "12'").
;; DSLD convention: rafter length labels do not show inches when the
;; remainder is zero -- the rounding rule already snaps to whole feet.
(defun dsld-rpr-fmt-ft (n) (strcat (itoa n) "'"))

;; Format a pitch (integer or float) as a string: "6" or "6.5".
;; Whole-number pitches show no decimal; fractional pitches strip
;; trailing zeros so 6.50 -> "6.5".
(defun dsld-rpr-fmt-pitch (p / s)
  (cond
    ((not p) "?")
    ((or (= p (fix p)) (< (abs (- p (float (fix p)))) 0.001))
     (itoa (fix p)))
    (T
     (setq s (rtos p 2 2))         ; mode 2 = decimal, prec 2
     (while (and (> (strlen s) 0)
                 (= (substr s (strlen s)) "0"))
       (setq s (substr s 1 (1- (strlen s)))))
     (if (and (> (strlen s) 0)
              (= (substr s (strlen s)) "."))
       (setq s (substr s 1 (1- (strlen s)))))
     s)))

;; Parse a pitch text "N/12" or "N.5/12" -> real, or nil.
;; Also strips MTEXT formatting codes like {\fArial|...;7/12}.
(defun dsld-rpr-parse-pitch (s / m i j)
  (if (and s (= (type s) 'STR))
    (progn
      ;; Strip common MTEXT formatting: backslash codes and curly braces.
      ;; The ";" search starts AT the backslash (third arg), otherwise a
      ;; ";" occurring before the first "\\" made the loop re-assemble
      ;; the same string forever (v1.8.0 fix).
      (while (setq i (vl-string-position (ascii "\\") s))
        (setq j (vl-string-search ";" s i))
        (setq s (strcat (substr s 1 i)
                        (if j (substr s (+ j 2)) ""))))
      (setq s (vl-string-translate "{}" "  " s))
      (setq s (vl-string-trim " \t\r\n" s))
      (if (wcmatch s "*/ 12,*/12,* / 12,*/ 12 ,*/12 ")
        (progn
          (setq m (substr s 1 (vl-string-search "/" s)))
          (setq m (vl-string-trim " \t" m))
          ;; distof returns a real (handles "6" or "6.5") -- keep it
          ;; real so fractional pitches like 6.5/12 are preserved.
          (if (and (> (strlen m) 0) (distof m))
            (distof m)))))))

;; Read pitch from an INSERT entity by trying:
;;   1. Dynamic block properties (any property whose value matches N/12)
;;   2. ATTRIB sub-entities (TEXT VALUE in group 1)
;; Returns integer N or nil.
(defun dsld-rpr-pitch-from-insert (ename / obj props p val pitch ent sub)
  (setq pitch nil)
  ;; --- 1. Dynamic block lookup properties ---
  (setq obj (vlax-ename->vla-object ename))
  (if (and (vlax-property-available-p obj 'IsDynamicBlock)
           (= (vla-get-IsDynamicBlock obj) :vlax-true))
    (progn
      (setq props (vlax-invoke obj 'GetDynamicBlockProperties))
      (foreach p props
        (if (not pitch)
          (progn
            (setq val (vlax-get p 'Value))
            (if (and val (= (type val) 'STR))
              (setq pitch (dsld-rpr-parse-pitch val))))))))
  ;; --- 2. Walk ATTRIB sub-entities ---
  (if (not pitch)
    (progn
      (setq sub (entnext ename))
      (while (and sub (not pitch))
        (setq ent (entget sub))
        (if (= (cdr (assoc 0 ent)) "ATTRIB")
          (setq pitch (dsld-rpr-parse-pitch (cdr (assoc 1 ent)))))
        (if (= (cdr (assoc 0 ent)) "SEQEND")
          (setq sub nil)
          (setq sub (entnext sub))))))
  pitch)

;; Look up pitch->color, fall back to a generated color if unmapped.
;; For fractional pitches (e.g. 6.5), round to nearest whole-number
;; pitch for the color-map lookup so 6.5/12 shows up next to 6/12 and
;; 7/12 with a related-but-distinct generated hue.
(defun dsld-rpr-pitch-color (p / pint hit)
  ;; NOTE: never name a local "pi" -- AutoLISP is dynamically scoped,
  ;; so it shadows the constant for every callee (v1.9.9 lesson).
  (setq pint (fix (+ p 0.5)))
  (setq hit (assoc pint *DSLD-RPR-COLOR-MAP*))
  (cond
    ((and hit (= p pint)) (cdr hit))    ; exact whole number, use map
    (hit                                ; fractional near a mapped value
     ;; Shift by half-step worth of palette so 6.5 != 6 and != 7.
     (1+ (rem (+ (cdr hit) 43) 250)))
    (T (1+ (rem (fix (* p 17)) 250)))))

;; Ensure a text style exists pointing to Lucida Bright (LBRITE.TTF) at
;; DSLD's standard width factor.  No-op if the style is already defined.
(defun dsld-rpr-ensure-text-style (name font width / )
  (if (not (tblsearch "STYLE" name))
    (entmake
      (list
        '(0 . "STYLE")
        '(100 . "AcDbSymbolTableRecord")
        '(100 . "AcDbTextStyleTableRecord")
        (cons 2 name)
        (cons 70 0)
        (cons 40 0.0)              ; fixed text height (0 = not fixed)
        (cons 41 width)            ; width factor
        (cons 50 0.0)              ; oblique angle
        (cons 71 0)                ; generation flags
        (cons 42 (* width 1.0))    ; last height used
        (cons 3 font)              ; primary font filename
        (cons 4 ""))))             ; bigfont (none)
  name)

;; Ensure a "*SSS" layer exists; create as a copy of source layer's color/lt.
(defun dsld-rpr-ensure-layer (new-name src-name / src clr lt lw rec)
  (if (not (tblsearch "LAYER" new-name))
    (progn
      (setq src (tblsearch "LAYER" src-name))
      (setq clr (if src (cdr (assoc 62 src)) 7))
      (setq lt  (if src (cdr (assoc 6  src)) "Continuous"))
      (setq lw  (if (and src (assoc 370 src)) (cdr (assoc 370 src)) -3))
      (if (minusp clr) (setq clr (abs clr)))
      (setq rec (list
                  '(0 . "LAYER")
                  '(100 . "AcDbSymbolTableRecord")
                  '(100 . "AcDbLayerTableRecord")
                  (cons 2 new-name)
                  (cons 70 0)
                  (cons 62 clr)
                  (cons 6 (if (or (not lt) (= lt "")) "Continuous" lt))
                  (cons 370 lw)))
      (entmake rec)))
  new-name)

;; Run BPOLY at a point.  Retries with escalating gap tolerances and
;; small perpendicular offsets if the first attempt fails -- some
;; drawings have wider gaps in the roof structure than the default
;; tolerance, and pick points that land too close to a line can confuse
;; BPOLY.  Returns the new boundary entity name or nil.
(defun dsld-rpr-bpoly-at (pt / sgap result tols offsets t-val o-val
                              try-pt before after)
  (setq sgap (getvar "HPGAPTOL"))
  ;; Stash so the command-level *error* handler restores HPGAPTOL if
  ;; the user Escs / errors while a retry loop is mid-flight.
  (dsld-rpr-stash 'hpgaptol sgap)
  (setq tols (list *DSLD-RPR-GAP-TOL*
                   (* *DSLD-RPR-GAP-TOL* 2.0)
                   (* *DSLD-RPR-GAP-TOL* 4.0)))
  (setq offsets '((0.0 0.0)
                  (3.0 0.0) (-3.0 0.0) (0.0 3.0) (0.0 -3.0)
                  (5.0 5.0) (-5.0 5.0) (5.0 -5.0) (-5.0 -5.0)))
  (foreach t-val tols
    (if (not result)
      (foreach o-val offsets
        (if (not result)
          (progn
            (setvar "HPGAPTOL" t-val)
            (setq try-pt (list (+ (car  pt) (car  o-val))
                               (+ (cadr pt) (cadr o-val))
                               0.0))
            (setq before (entlast))
            (vl-catch-all-apply
              '(lambda () (command "_.-BOUNDARY" try-pt "")))
            (setq after (entlast))
            (if (and after (not (eq before after)))
              (setq result after)))))))
  (setvar "HPGAPTOL" sgap)
  result)

;;-----------------------------------------------------------------------;;
;; Auto-close: trace an OPEN area from a click (v1.9.0)
;;-----------------------------------------------------------------------;;
;; Real plans have areas that no gap tolerance can close -- porch and
;; eave strips genuinely open on one (or two) sides.  When BPOLY fails
;; at a click, these helpers find DANGLING endpoints (curve ends that
;; touch no other roof curve) near the click, temporarily bridge the
;; most promising pair(s) with a LINE, re-run BPOLY, then delete the
;; bridges.  This is RPRAREA's manual bridge, automated.

;; Start/end points of any curve entity, or nil.
(defun dsld-rpr-curve-ends (e / sp ep)
  (setq sp (vl-catch-all-apply 'vlax-curve-getStartPoint (list e)))
  (setq ep (vl-catch-all-apply 'vlax-curve-getEndPoint   (list e)))
  (if (or (vl-catch-all-error-p sp) (vl-catch-all-error-p ep))
    nil
    (list sp ep)))

;; Distance from point p to the nearest point on curve e.
(defun dsld-rpr-dist-to-curve (e p / cp)
  (setq cp (vl-catch-all-apply 'vlax-curve-getClosestPointTo (list e p)))
  (if (vl-catch-all-error-p cp) 1.0e99 (distance p cp)))

;; Dangling endpoints among CURVES: endpoints farther than GAP-TOL
;; from every OTHER curve.  Returns list of (point . owner-ename).
(defun dsld-rpr-find-dangling (curves / out e ends p other mind d)
  (setq out '())
  (foreach e curves
    (setq ends (dsld-rpr-curve-ends e))
    (if ends
      (foreach p ends
        (setq mind 1.0e99)
        (foreach other curves
          (if (not (eq other e))
            (progn
              (setq d (dsld-rpr-dist-to-curve other p))
              (if (< d mind) (setq mind d)))))
        (if (> mind *DSLD-RPR-GAP-TOL*)
          (setq out (cons (cons p e) out))))))
  out)

;; Try bridging candidate endpoint pairs one at a time.  Each pair is
;; ((pt-a . ent-a) (pt-b . ent-b)).  Returns the traced region whose
;; interior contains pt, or nil.  Bridges are always deleted.
(defun dsld-rpr-try-bridges (pt pairs / pair a b lay tmp region out)
  (foreach pair pairs
    (if (not out)
      (progn
        (setq a (car pair) b (cadr pair))
        (setq lay (cdr (assoc 8 (entget (cdr a)))))
        (setq tmp (entmakex (list '(0 . "LINE") (cons 8 lay)
                                  (cons 10 (car a)) (cons 11 (car b)))))
        (setq region (dsld-rpr-bpoly-at pt))
        (if tmp (entdel tmp))
        (cond
          ((and region (dsld-rpr-pt-in-poly pt region))
           (setq out region))
          (region (entdel region))))))
  out)

;; BPOLY with auto-close fallback.  lay-filter is an ssget layer
;; filter string ("A-Roof,A-Roof-Hidd,...") naming the layers whose
;; curves may participate in bridging -- pass the same layers that are
;; visible for tracing.  Tries: normal BPOLY -> single bridge across
;; the best few dangling pairs -> two simultaneous bridges (area open
;; on two sides).
(defun dsld-rpr-bpoly-auto-close (pt lay-filter / region w wx1 wy1 wx2 wy2
                                    ss e ends curves dangls n i j a b d
                                    scored pairs p1e p2e lay tmp1 tmp2
                                    best bestd cp dirx diry)
  (setq region (dsld-rpr-bpoly-at pt))
  (cond
    (region region)
    (T
     ;; collect roof curves with an endpoint near the click (40 ft)
     (setq w 480.0)
     (setq wx1 (- (car pt) w) wy1 (- (cadr pt) w)
           wx2 (+ (car pt) w) wy2 (+ (cadr pt) w))
     (setq ss (ssget "_X"
                (list '(0 . "LINE,ARC,LWPOLYLINE,POLYLINE,SPLINE,ELLIPSE")
                      (cons 8 lay-filter))))
     (setq curves '())
     (foreach e (dsld-rpr-ss->list ss)
       (setq ends (dsld-rpr-curve-ends e))
       (if (and ends
                (or (and (>= (car (car ends)) wx1) (<= (car (car ends)) wx2)
                         (>= (cadr (car ends)) wy1) (<= (cadr (car ends)) wy2))
                    (and (>= (car (cadr ends)) wx1) (<= (car (cadr ends)) wx2)
                         (>= (cadr (cadr ends)) wy1) (<= (cadr (cadr ends)) wy2))))
         (setq curves (cons e curves))))
     ;; --- Step-inside heuristic (v1.9.0) --------------------------
     ;; Pitch tags are routinely placed just OUTSIDE the region they
     ;; label (leader-style) -- verified against a production plan
     ;; where 8 tags sat ~7in below the eave line.  If a roof curve
     ;; passes within 60in of the pick, step toward it and just PAST
     ;; it, then trace from the far side.  The main loop's dedupe
     ;; collapses any duplicate trace of an already-traced region.
     (setq best nil bestd 1.0e99)
     (foreach e curves
       (setq d (dsld-rpr-dist-to-curve e pt))
       (if (< d bestd) (setq bestd d best e)))
     (cond
       ((and best (< bestd 60.0) (> bestd 0.01))
        (setq cp (vl-catch-all-apply
                   'vlax-curve-getClosestPointTo (list best pt)))
        (cond
          ((not (vl-catch-all-error-p cp))
           (setq dirx (/ (- (car cp) (car pt)) bestd)
                 diry (/ (- (cadr cp) (cadr pt)) bestd))
           (foreach step (list (+ bestd 6.0) (+ bestd 18.0))
             (if (not region)
               (setq region
                     (dsld-rpr-bpoly-at
                       (list (+ (car pt) (* dirx step))
                             (+ (cadr pt) (* diry step))
                             0.0)))))))))
     (if region
       region
       (progn
     (setq dangls (dsld-rpr-find-dangling curves))
     ;; score all pairs (different owners or not, just not same point):
     ;; shorter bridges + nearer to the click first
     (setq scored '() n (length dangls) i 0)
     (while (< i n)
       (setq j (1+ i))
       (while (< j n)
         (setq a (nth i dangls) b (nth j dangls))
         (setq d (distance (car a) (car b)))
         (if (and (> d 0.5) (<= d 480.0))
           (setq scored
                 (cons (list (+ d
                                (distance (car a) pt)
                                (distance (car b) pt))
                             a b)
                       scored)))
         (setq j (1+ j)))
       (setq i (1+ i)))
     (setq scored (vl-sort scored '(lambda (x y) (< (car x) (car y)))))
     ;; single-bridge attempts on the best 6 pairs
     (setq pairs '())
     (setq i 0)
     (foreach s scored
       (if (< i 6)
         (progn (setq pairs (append pairs (list (list (cadr s) (caddr s)))))
                (setq i (1+ i)))))
     (setq region (dsld-rpr-try-bridges pt pairs))
     ;; two-bridge attempt: best pair + the best pair sharing no endpoint
     (cond
       ((and (not region) (>= (length pairs) 2))
        (setq p1e (car pairs))
        (setq p2e nil)
        (foreach cand (cdr pairs)
          (if (and (not p2e)
                   (not (equal (car (car  cand)) (car (car  p1e))))
                   (not (equal (car (car  cand)) (car (cadr p1e))))
                   (not (equal (car (cadr cand)) (car (car  p1e))))
                   (not (equal (car (cadr cand)) (car (cadr p1e)))))
            (setq p2e cand)))
        (cond
          (p2e
           (setq lay (cdr (assoc 8 (entget (cdr (car p1e))))))
           (setq tmp1 (entmakex (list '(0 . "LINE") (cons 8 lay)
                                      (cons 10 (car (car  p1e)))
                                      (cons 11 (car (cadr p1e))))))
           (setq tmp2 (entmakex (list '(0 . "LINE") (cons 8 lay)
                                      (cons 10 (car (car  p2e)))
                                      (cons 11 (car (cadr p2e))))))
           (setq region (dsld-rpr-bpoly-at pt))
           (if tmp1 (entdel tmp1))
           (if tmp2 (entdel tmp2))
           (cond
             ((and region (not (dsld-rpr-pt-in-poly pt region)))
              (entdel region)
              (setq region nil)))))))
     region)))))

;; Turn off every layer NOT in keep-list (case-insensitive) using the proper
;; ActiveX API.  Returns the list of layer names turned off, for restoration.
;; Using vla-put-LayerOn instead of entmod-based color-sign trick so the
;; visibility change actually takes effect in BricsCAD.
(defun dsld-rpr-isolate-layers (keep-list / keep-up doc layers off-list)
  (setq keep-up (mapcar 'strcase keep-list))
  (setq off-list '())
  (setq doc (vla-get-activedocument (vlax-get-acad-object)))
  (setq layers (vla-get-layers doc))
  (vlax-for lay layers
    (if (and (not (member (strcase (vla-get-name lay)) keep-up))
             (= (vla-get-layeron lay) :vlax-true))
      (progn
        (vla-put-layeron lay :vlax-false)
        (setq off-list (cons (vla-get-name lay) off-list)))))
  off-list)

;; Restore visibility for previously-isolated layers.  Uses vla-Item
;; (direct name lookup, O(1) per layer) instead of iterating the entire
;; layer collection -- on a 500-layer DSLD template the iteration form
;; took ~500ms before the BBOX prompt.
(defun dsld-rpr-restore-layers (off-list / doc layers n lay)
  (setq doc (vla-get-activedocument (vlax-get-acad-object)))
  (setq layers (vla-get-layers doc))
  (foreach n off-list
    (vl-catch-all-apply
      '(lambda ()
         (setq lay (vla-Item layers n))
         (vla-put-layeron lay :vlax-true)))))

;; Set a list of layers to ON (:vlax-true) or OFF (:vlax-false).  Layers
;; that don't exist are silently skipped.  Uses vla-Item lookup per
;; name (O(1)) instead of vlax-for over all layers -- this is on the
;; RPR pass-1 hot path right before the BBOX prompt, so the iteration-
;; form was a multi-hundred-millisecond stall on large drawings.
(defun dsld-rpr-set-layers-on (lay-names on-flag / doc layers n lay)
  (setq doc (vla-get-activedocument (vlax-get-acad-object)))
  (setq layers (vla-get-layers doc))
  (foreach n lay-names
    (vl-catch-all-apply
      '(lambda ()
         (setq lay (vla-Item layers n))
         (vla-put-layeron lay on-flag)))))

;; Bounding-box center of an entity (works for blocks, polylines, etc.)
;; Insertion point of a dynamic block sits at the anchor, which often falls
;; on a roof line or outside the visible block; the bbox center is reliably
;; inside the visible block footprint and therefore inside the roof zone.
(defun dsld-rpr-bbox-center-ent (ename / o lo hi)
  (setq o (vlax-ename->vla-object ename))
  (vla-GetBoundingBox o 'lo 'hi)
  (mapcar '(lambda (a b) (/ (+ a b) 2.0))
          (vlax-safearray->list lo)
          (vlax-safearray->list hi)))

;; Area of an LWPOLYLINE region by bounding box (rough but sufficient
;; for "is this BPOLY trace WAY too big?" rejection).
(defun dsld-rpr-region-bbox-area (region / bb)
  (setq bb (dsld-rpr-poly-bbox region))
  (* (- (car (cadr bb)) (car (car bb)))
     (- (cadr (cadr bb)) (cadr (car bb)))))

;; Find longest edge of an LWPOLYLINE; return its angle (radians).
(defun dsld-rpr-longest-edge-angle (poly / e verts n i p1 p2 d a best-d best-a)
  (setq e (entget poly))
  (setq verts (vl-remove-if-not '(lambda (x) (= 10 (car x))) e))
  (setq n (length verts) i 0 best-d 0.0 best-a 0.0)
  (while (< i n)
    (setq p1 (cdr (nth i verts)))
    (setq p2 (cdr (nth (rem (1+ i) n) verts)))
    (setq d (distance p1 p2))
    (if (> d best-d)
      (progn (setq best-d d) (setq best-a (angle p1 p2))))
    (setq i (1+ i)))
  best-a)

;; Bounding box of an LWPOLYLINE -> (minpt maxpt).
;; Bounding box of a closed LWPOLYLINE as (lo-pt hi-pt), each (x y 0.0).
;; v1.9.5: computed from the polyline's own group-10 vertices in pure
;; LISP -- no ActiveX.  The old vla-GetBoundingBox version needed
;; vlax-ename->vla-object, which fails when the document-level ActiveX
;; layer is absent (headless core console), and cost a COM round-trip
;; on every call in a hot path (peak detection, holes, chart, labels).
;; Roof regions are straight-edged, so vertex extents equal the true
;; bbox; if a rare arc segment ever needs its bulge accounted for, that
;; can be added, but it never mattered for RPR's approximate uses.
(defun dsld-rpr-poly-bbox (poly / verts xs ys)
  (setq verts (dsld-rpr-poly-vertices poly))
  (cond
    ((null verts)
     ;; degenerate guard: fall back to ActiveX bbox if somehow no verts
     (vl-catch-all-apply
       '(lambda ( / o lo hi)
          (setq o (vlax-ename->vla-object poly))
          (vla-GetBoundingBox o 'lo 'hi)
          (list (vlax-safearray->list lo) (vlax-safearray->list hi)))))
    (T
     (setq xs (mapcar 'car verts) ys (mapcar 'cadr verts))
     (list (list (apply 'min xs) (apply 'min ys) 0.0)
           (list (apply 'max xs) (apply 'max ys) 0.0)))))

;; Centroid of polyline bbox (good enough for hatch origin / region anchor).
(defun dsld-rpr-bbox-center (bb)
  (mapcar '(lambda (a b) (/ (+ a b) 2.0)) (car bb) (cadr bb)))

;; Test if a 2D point is inside a closed LWPOLYLINE (ray casting).
(defun dsld-rpr-pt-in-poly (pt poly / e verts n i p1 p2 inside x y xi yi xj yj)
  (setq e (entget poly))
  (setq verts (vl-remove-if-not '(lambda (x) (= 10 (car x))) e))
  (setq n (length verts) i 0 inside nil)
  (setq x (car pt) y (cadr pt))
  (while (< i n)
    (setq p1 (cdr (nth i verts)))
    (setq p2 (cdr (nth (rem (1+ i) n) verts)))
    (setq xi (car p1) yi (cadr p1) xj (car p2) yj (cadr p2))
    (if (and (/= (> yi y) (> yj y))
             (< x (+ xi (* (- xj xi) (/ (- y yi) (if (zerop (- yj yi)) 1e-9 (- yj yi)))))))
      (setq inside (not inside)))
    (setq i (1+ i)))
  inside)

;;-----------------------------------------------------------------------;;
;; Selection helpers
;;-----------------------------------------------------------------------;;

;; Build ssget filter for roof-structure lines on the configured layers.
(defun dsld-rpr-roof-filter ()
  (list
    '(0 . "LINE,LWPOLYLINE,POLYLINE,ARC")
    (cons 8 (apply 'strcat (dsld-rpr-comma-join *DSLD-RPR-ROOF-LAYERS*)))))

(defun dsld-rpr-comma-join (lst / first)
  (setq first T)
  (mapcar
    '(lambda (s)
       (if first (progn (setq first nil) s) (strcat "," s)))
    lst))

;; Find pitch callouts inside a crossing window.  Looks at TEXT, MTEXT, and
;; INSERT (dynamic-block) entities on any layer (DSLD pitch tags on
;; A-Anno-Note are dynamic blocks; we don't want a strict layer filter to
;; miss them if a project is layered slightly differently).
;; Returns list of (insertion-point . pitch-int).
(defun dsld-rpr-find-pitch-text (p1 p2 / ss n i e etype val pt out)
  (setq ss (ssget "_C" p1 p2 '((0 . "TEXT,MTEXT,INSERT"))))
  (setq out '())
  (if ss
    (progn
      (setq n (sslength ss) i 0)
      (while (< i n)
        (setq e (entget (ssname ss i)))
        (setq etype (cdr (assoc 0 e)))
        (cond
          ((or (= etype "TEXT") (= etype "MTEXT"))
           (setq val (dsld-rpr-parse-pitch (cdr (assoc 1 e))))
           (if val
             (setq out (cons (cons (cdr (assoc 10 e)) val) out))))
          ((= etype "INSERT")
           (setq val (dsld-rpr-pitch-from-insert (ssname ss i)))
           (if val
             ;; Use the block's bbox center (reliably inside visible block)
             ;; instead of group 10 insertion point which can fall on a
             ;; roof line and confuse BPOLY.
             (setq out (cons (cons (dsld-rpr-bbox-center-ent (ssname ss i))
                                   val)
                             out)))))
        (setq i (1+ i)))))
  (reverse out))

;;-----------------------------------------------------------------------;;
;; Rafter generation per region
;;-----------------------------------------------------------------------;;

;; All vertex points (group 10) of a closed LWPOLYLINE.
(defun dsld-rpr-poly-vertices (poly / e)
  (setq e (entget poly))
  (mapcar 'cdr (vl-remove-if-not '(lambda (x) (= 10 (car x))) e)))

;; Is edge (p1 p2) of self-poly also an edge of any other polygon in
;; all-polys?  Compared with *DSLD-RPR-GAP-TOL* tolerance on both
;; endpoints, in either direction.
(defun dsld-rpr-edge-shared-p (p1 p2 self-poly all-polys / tol found
                                 poly verts n i a b)
  (setq tol *DSLD-RPR-GAP-TOL*)
  (setq found nil)
  (foreach poly all-polys
    (if (and (not (eq poly self-poly)) (not found))
      (progn
        (setq verts (dsld-rpr-poly-vertices poly))
        (setq n (length verts) i 0)
        (while (and (< i n) (not found))
          (setq a (nth i verts))
          (setq b (nth (rem (1+ i) n) verts))
          (if (or (and (< (distance p1 a) tol) (< (distance p2 b) tol))
                  (and (< (distance p1 b) tol) (< (distance p2 a) tol)))
            (setq found T))
          (setq i (1+ i))))))
  found)

;; Classify each edge of region as shared (with another polygon = ridge/hip)
;; or non-shared (= eave on building perimeter).
;; Returns (shared-list . non-shared-list); each entry is (p1 p2 length).
(defun dsld-rpr-classify-edges (region all-polys / verts n i v1 v2 d sh ns)
  (setq verts (dsld-rpr-poly-vertices region))
  (setq n (length verts) i 0 sh '() ns '())
  (while (< i n)
    (setq v1 (nth i verts))
    (setq v2 (nth (rem (1+ i) n) verts))
    (setq d (distance v1 v2))
    (if (dsld-rpr-edge-shared-p v1 v2 region all-polys)
      (setq sh (cons (list v1 v2 d) sh))
      (setq ns (cons (list v1 v2 d) ns)))
    (setq i (1+ i)))
  (cons sh ns))

;; Longest edge from a list of (p1 p2 length) entries, or nil.
(defun dsld-rpr-longest-of (edges / best)
  (if edges
    (progn
      (setq best (car edges))
      (foreach e edges
        (if (> (caddr e) (caddr best)) (setq best e)))
      best)))

;; Peak of region given its eave edge.  The peak is the vertex (or set of
;; tied vertices) furthest from the eave perpendicular to it.
;;   - rectangular slope: ridge has 2+ vertices tied at max distance ->
;;     return midpoint of those (ridge midpoint).
;;   - triangular hip end: apex is the single furthest vertex -> return it.
(defun dsld-rpr-find-peak (region eave-edge / verts eave-ang perp-ang
                            perp-x perp-y eave-mid eave-proj
                            projs max-d tied tol sumx sumy n)
  (setq verts (dsld-rpr-poly-vertices region))
  (setq eave-ang (angle (car eave-edge) (cadr eave-edge)))
  (setq perp-ang (+ eave-ang (/ pi 2.0)))
  (setq perp-x (cos perp-ang))
  (setq perp-y (sin perp-ang))
  (setq eave-mid (mapcar '(lambda (a b) (/ (+ a b) 2.0))
                         (car eave-edge) (cadr eave-edge)))
  (setq eave-proj (+ (* (car eave-mid) perp-x) (* (cadr eave-mid) perp-y)))
  ;; absolute distance from eave for each vertex
  (setq projs (mapcar
                '(lambda (v)
                   (cons (abs (- (+ (* (car v) perp-x) (* (cadr v) perp-y))
                                 eave-proj))
                         v))
                verts))
  (setq max-d (apply 'max (mapcar 'car projs)))
  (setq tol 0.5)                       ; 1/2" tolerance for "tied"
  (setq tied (mapcar 'cdr
                     (vl-remove-if-not
                       '(lambda (p) (> (car p) (- max-d tol)))
                       projs)))
  (cond
    ((= (length tied) 1) (car tied))
    (T
     (setq sumx 0.0 sumy 0.0 n (length tied))
     (foreach v tied
       (setq sumx (+ sumx (car v)))
       (setq sumy (+ sumy (cadr v))))
     (list (/ sumx n) (/ sumy n) 0.0))))

;; Pure-LISP intersection of two 2D line segments.  Returns the
;; intersection point as (x y 0) if it lies in the closed parameter
;; range [0,1] for both segments, or nil otherwise.  No ActiveX, no temp
;; entities -- fast and BricsCAD/AutoCAD safe.
(defun dsld-rpr-segs-intersect (p1 p2 p3 p4 /
                                 x1 y1 x2 y2 x3 y3 x4 y4
                                 denom t-num u-num pt-t pt-u eps)
  (setq eps 1e-9)
  (setq x1 (car p1) y1 (cadr p1)
        x2 (car p2) y2 (cadr p2)
        x3 (car p3) y3 (cadr p3)
        x4 (car p4) y4 (cadr p4))
  (setq denom (- (* (- x1 x2) (- y3 y4))
                 (* (- y1 y2) (- x3 x4))))
  (if (< (abs denom) eps)
    nil                                          ; segments are parallel
    (progn
      (setq t-num (- (* (- x1 x3) (- y3 y4))
                     (* (- y1 y3) (- x3 x4))))
      (setq u-num (- (* (- y1 y2) (- x1 x3))
                     (* (- x1 x2) (- y1 y3))))
      (setq pt-t  (/ t-num denom))
      (setq pt-u  (/ u-num denom))
      (if (and (>= pt-t (- eps)) (<= pt-t (+ 1.0 eps))
               (>= pt-u (- eps)) (<= pt-u (+ 1.0 eps)))
        (list (+ x1 (* pt-t (- x2 x1)))
              (+ y1 (* pt-t (- y2 y1)))
              0.0)))))

;; Intersection points between a single line segment (p1-p2) and the
;; closed polygon defined by REGION.  Walks each polygon edge using
;; pure-LISP segment intersection.  Returns list of (x y 0) points,
;; possibly empty.  De-dupes points within ~1/64" so a rafter passing
;; exactly through a vertex doesn't double-count.
(defun dsld-rpr-line-poly-intersect (p1 p2 region / verts n i v1 v2 hit
                                      out dup p)
  (setq verts (dsld-rpr-poly-vertices region))
  (setq n (length verts) i 0 out '())
  (while (< i n)
    (setq v1 (nth i verts))
    (setq v2 (nth (rem (1+ i) n) verts))
    (if (setq hit (dsld-rpr-segs-intersect p1 p2 v1 v2))
      (progn
        (setq dup nil)
        (foreach p out
          (if (< (distance hit p) 0.02) (setq dup T)))
        (if (not dup) (setq out (cons hit out)))))
    (setq i (1+ i)))
  out)

;; Clip a line segment to the inside of a closed polygon.  Returns a list
;; of inside-segments, each as (start-pt end-pt).  Handles the cases:
;;   - line entirely outside (-> nil)
;;   - line entirely inside  (-> (list (start end)))
;;   - line crossing in/out  (-> one or more inside segments)
;; v1.9.13: intervals are validated by MIDPOINT instead of blind
;; (0,1)(2,3) pairing.  A scanline that grazes a polygon VERTEX yields
;; an odd/duplicated crossing; pair-stepping then shifted every
;; subsequent pair and emitted segments OUTSIDE the region (a 12/12
;; rafter reached 55" into the neighboring 8/12 plane on the real
;; roof).  Testing each consecutive interval's midpoint keeps exactly
;; the inside spans no matter how the crossing list is corrupted.
(defun dsld-rpr-clip-line (p-start p-end region / inters sorted segs i
                            mid a b)
  (setq inters (dsld-rpr-line-poly-intersect p-start p-end region))
  (cond
    ((null inters)
     (setq mid (mapcar '(lambda (a b) (/ (+ a b) 2.0)) p-start p-end))
     (if (dsld-rpr-pt-in-poly mid region)
       (list (list p-start p-end))))
    (T
     (setq sorted (vl-sort inters
                    '(lambda (a b)
                       (< (distance p-start a) (distance p-start b)))))
     (setq sorted (append (list p-start) sorted (list p-end)))
     (setq segs '() i 0)
     (while (< (1+ i) (length sorted))
       (setq a (nth i sorted) b (nth (1+ i) sorted))
       (setq mid (mapcar '(lambda (m n) (/ (+ m n) 2.0)) a b))
       (if (and (> (distance a b) 0.5)
                (dsld-rpr-pt-in-poly mid region))
         (setq segs (cons (list a b) segs)))
       (setq i (1+ i)))
     (reverse segs))))

;; Generate rafters as LINE entities clipped to the polygon, perpendicular
;; to the longest edge of the region.  Spacing is along the longest-edge
;; axis.  Bypasses HATCH+EXPLODE entirely so rafter geometry is guaranteed
;; to stay inside the polygon and on layer A-RoofSSS.
;; Centroid of the entire roof = average of bbox-centers of all polygons.
;; Used as a reference to identify the "interior" side of each slope.
(defun dsld-rpr-overall-centroid (all-polys / pts sum-x sum-y n)
  (setq pts (mapcar
              '(lambda (p) (dsld-rpr-bbox-center (dsld-rpr-poly-bbox p)))
              all-polys))
  (setq n (length pts) sum-x 0.0 sum-y 0.0)
  (foreach pt pts
    (setq sum-x (+ sum-x (car pt)))
    (setq sum-y (+ sum-y (cadr pt))))
  (list (/ sum-x n) (/ sum-y n) 0.0))

;; True if two bboxes (each (lo hi)) touch/overlap when inflated by tol.
(defun dsld-rpr-bbox-touch-p (a b tol)
  (and (<= (- (car  (car a)) tol) (car  (cadr b)))
       (>= (+ (car  (cadr a)) tol) (car  (car b)))
       (<= (- (cadr (car a)) tol) (cadr (cadr b)))
       (>= (+ (cadr (cadr a)) tol) (cadr (car b)))))

;; Connected cluster of regions containing REGION: BFS over bbox
;; adjacency (24" inflation).  v1.9.8: a scan window can cover SEVERAL
;; plan copies; averaging bbox-centers across every copy put the "roof
;; centroid" in the empty space between houses, so peak-by-centroid
;; picked ridge points facing the wrong way ("point of origin is
;; incorrect").  Each house's regions form one adjacency cluster --
;; peak and callout side selection must use THAT house's centroid.
(defun dsld-rpr-cluster-polys (region all-polys / boxes cluster changed
                                pb p hit c)
  (dsld-rpr-dbg (strcat "    cluster: enter n=" (itoa (length all-polys))))
  (setq boxes '())
  (foreach p all-polys
    (setq boxes (cons (cons p (dsld-rpr-poly-bbox p)) boxes)))
  (setq cluster (list region))
  (setq changed T)
  (while changed
    (setq changed nil)
    (foreach pb boxes
      (setq p (car pb))
      (cond
        ((member p cluster) nil)
        (T
         (setq hit nil)
         (foreach c cluster
           (if (and (not hit)
                    (dsld-rpr-bbox-touch-p (cdr (assoc c boxes)) (cdr pb)
                                           24.0))
             (setq hit T)))
         (cond
           (hit (setq cluster (cons p cluster))
                (setq changed T)))))))
  (dsld-rpr-dbg (strcat "    cluster: exit size=" (itoa (length cluster))))
  cluster)

;; Partition every poly into its adjacency cluster (list of lists).
(defun dsld-rpr-partition-clusters (all-polys / rest cl out)
  (setq rest all-polys out '())
  (while rest
    (setq cl (dsld-rpr-cluster-polys (car rest) rest))
    (setq out (cons cl out))
    (setq rest (vl-remove-if '(lambda (p) (member p cl)) rest)))
  out)

;; Peak of a polygon = its vertex OR edge-midpoint that is closest to
;; the roof centroid OF ITS OWN HOUSE (adjacency cluster, v1.9.8).
;;   - rectangular slope: ridge edge midpoint wins (it's the interior side)
;;   - triangular hip end: apex vertex wins
(defun dsld-rpr-find-peak-by-centroid (region all-polys /
                                        building-c verts n i v1 v2 mid d
                                        best-d best-pt)
  (setq building-c (dsld-rpr-overall-centroid
                     (dsld-rpr-cluster-polys region all-polys)))
  (setq verts (dsld-rpr-poly-vertices region))
  (setq n (length verts) best-d nil best-pt nil)
  ;; Check every vertex
  (foreach v verts
    (setq d (distance v building-c))
    (if (or (null best-d) (< d best-d))
      (progn (setq best-d d) (setq best-pt v))))
  ;; Check every edge midpoint
  (setq i 0)
  (while (< i n)
    (setq v1 (nth i verts))
    (setq v2 (nth (rem (1+ i) n) verts))
    (setq mid (mapcar '(lambda (a b) (/ (+ a b) 2.0)) v1 v2))
    (setq d (distance mid building-c))
    (if (< d best-d) (progn (setq best-d d) (setq best-pt mid)))
    (setq i (1+ i)))
  best-pt)

;; Identify "bell" segments: short rafter segments along the DRIP EDGE
;; (i.e. close to the polygon's bbox perimeter) that line up with at
;; least *DSLD-RPR-BELL-RUN-MIN*-1 OTHER short segments of similar
;; length.  Strictly drip-edge-only -- internal rows of same-length
;; rafters (e.g. a uniform middle-of-the-roof zone) are NOT flagged
;; because their midpoints are away from the bbox edge.
;; Returns the list of segments to discard.
(defun dsld-rpr-find-bell-segs (candidates rafter-dir region /
                                 bb min-pt max-pt edge-tol near-edge
                                 shorts s s-len s-mid other o-len o-mid
                                 mid-diff close-count excluded seg-len mid)
  ;; Bbox of region for drip-edge proximity test.
  (setq bb       (dsld-rpr-poly-bbox region))
  (setq min-pt   (car  bb))
  (setq max-pt   (cadr bb))
  (setq edge-tol *DSLD-RPR-BELL-MAX-LEN*)
  ;; Collect every SHORT, DRIP-EDGE segment as (seg length midpoint).
  (setq shorts '())
  (foreach c candidates
    (foreach seg (cadr c)
      (setq seg-len (distance (car seg) (cadr seg)))
      (if (< seg-len *DSLD-RPR-BELL-MAX-LEN*)
        (progn
          (setq mid (mapcar '(lambda (a b) (/ (+ a b) 2.0))
                            (car seg) (cadr seg)))
          (setq near-edge
                (or (< (- (car  mid) (car  min-pt)) edge-tol)
                    (< (- (car  max-pt) (car  mid)) edge-tol)
                    (< (- (cadr mid) (cadr min-pt)) edge-tol)
                    (< (- (cadr max-pt) (cadr mid)) edge-tol)))
          (if near-edge
            (setq shorts (cons (list seg seg-len mid) shorts)))))))
  ;; A segment is part of a bell if it has >= (BELL-RUN-MIN - 1) peers
  ;; whose midpoint is aligned with it (along rafter direction) and whose
  ;; length is within tolerance.  For horizontal rafters, peers share X
  ;; (rafters stack along Y); for vertical rafters, peers share Y.
  (setq excluded '())
  (foreach s shorts
    (setq s-len (cadr s)) (setq s-mid (caddr s))
    (setq close-count 0)
    (foreach other shorts
      (if (not (eq s other))
        (progn
          (setq o-len (cadr other)) (setq o-mid (caddr other))
          (setq mid-diff (if (zerop rafter-dir)
                             (abs (- (car  s-mid) (car  o-mid)))
                             (abs (- (cadr s-mid) (cadr o-mid)))))
          (if (and (< mid-diff *DSLD-RPR-BELL-MID-TOL*)
                   (< (abs (- s-len o-len)) *DSLD-RPR-BELL-LEN-TOL*))
            (setq close-count (1+ close-count))))))
    (if (>= close-count (1- *DSLD-RPR-BELL-RUN-MIN*))
      (setq excluded (cons (car s) excluded))))
  excluded)

;; Sub-regions of REGION that were captured as their own areas (dormer
;; under-roof strips, second-floor cutouts).  The parent's rafters and
;; SF must exclude them.  Containment = candidate's bbox-center inside
;; region, bbox nested (1" tol), and area under 85% of the parent's
;; (so two near-identical overlapping traces don't count each other).
(defun dsld-rpr-holes-of (region all-polys / ra rbb holes p pa pbb pc)
  (setq ra  (dsld-rpr-poly-area-flat region))
  (setq rbb (dsld-rpr-poly-bbox region))
  (setq holes '())
  (foreach p all-polys
    (cond
      ((eq p region) nil)
      (T
       (setq pa  (dsld-rpr-poly-area-flat p))
       (setq pbb (dsld-rpr-poly-bbox p))
       (setq pc  (dsld-rpr-bbox-center pbb))
       (if (and (< pa (* 0.85 ra))
                (dsld-rpr-pt-in-poly pc region)
                (>= (car  (car  pbb)) (- (car  (car  rbb)) 1.0))
                (>= (cadr (car  pbb)) (- (cadr (car  rbb)) 1.0))
                (<= (car  (cadr pbb)) (+ (car  (cadr rbb)) 1.0))
                (<= (cadr (cadr pbb)) (+ (cadr (cadr rbb)) 1.0)))
         (setq holes (cons p holes))))))
  holes)

;; True if two closed polygons have overlapping INTERIORS (not merely a
;; shared edge or vertex).  Samples points strictly inside each polygon
;; -- its bbox-center and the midpoints from that center to each vertex
;; -- and checks whether any land inside the other.  Edge-adjacent
;; regions (which share a boundary but have disjoint interiors) test
;; FALSE, so they are never clipped against each other.
;; v1.9.13: sampled-lattice implementation (shares dsld-rpr-overlap-frac).
;; The old bbox-center/midpoint sampling false-positived on shapes whose
;; bbox center sits ON a shared edge -- e.g. two right triangles that
;; meet along a hypotenuse (a valley-split slope pair).  Interior
;; overlap now means >5% of either region's lattice lies inside the
;; other; edge-adjacent regions test nil.
(defun dsld-rpr-regions-overlap-p (a b)
  ;; a SINGLE interior lattice hit counts: the offset lattice cannot
  ;; land on shared edges, so one hit is genuine interior overlap
  (or (> (dsld-rpr-overlap-frac a b) 0.01)
      (> (dsld-rpr-overlap-frac b a) 0.01)))

;; Regions whose rafters must be carved out of REGION's rafters (v1.9.6):
;; every SMALLER region whose interior overlaps REGION.  This subsumes
;; nested dormers (dsld-rpr-holes-of) AND adds PARTIAL overlaps -- an
;; added area that pokes across a hip/valley into a neighbor.  Without
;; it, both regions draw rafters in the overlap and they visibly cross
;; (the "added area went through the lines, intersecting rafters" bug).
;; Smaller-area region wins the overlap, so the result is deterministic
;; and edge-adjacent (non-overlapping) neighbors are never touched.
(defun dsld-rpr-rafter-clip-regions (region all-polys / ra clips p pa)
  (setq ra (dsld-rpr-poly-area-flat region) clips '())
  (foreach p all-polys
    (if (and (not (eq p region))
             (setq pa (dsld-rpr-poly-area-flat p))
             (< pa ra)                       ; smaller region owns overlap
             (dsld-rpr-regions-overlap-p region p))
      (setq clips (cons p clips))))
  clips)

;; Scalar position of point P along the unit direction DIR from A
;; (2D dot product).
(defun dsld-rpr-param-along (a dir p)
  (+ (* (- (car  p) (car  a)) (car  dir))
     (* (- (cadr p) (cadr a)) (cadr dir))))

;; 1D subtraction: remove the collinear sub-segments INSIDE-SEGS from
;; SEG (all points lie on one line).  Returns the surviving pieces,
;; dropping slivers under 1".
(defun dsld-rpr-interval-diff (seg inside-segs / a b len dir ivs s t1 t2
                                kept cur iv)
  (setq a (car seg) b (cadr seg))
  (setq len (distance a b))
  (cond
    ((< len 1e-6) nil)
    ((not inside-segs) (list seg))
    (T
     (setq dir (list (/ (- (car  b) (car  a)) len)
                     (/ (- (cadr b) (cadr a)) len)))
     (setq ivs '())
     (foreach s inside-segs
       (setq t1 (dsld-rpr-param-along a dir (car  s)))
       (setq t2 (dsld-rpr-param-along a dir (cadr s)))
       (setq ivs (cons (list (min t1 t2) (max t1 t2)) ivs)))
     (setq ivs (vl-sort ivs '(lambda (x y) (< (car x) (car y)))))
     (setq kept '() cur 0.0)
     (foreach iv ivs
       (if (> (- (car iv) cur) 1.0)
         (setq kept (cons (list cur (car iv)) kept)))
       (if (> (cadr iv) cur) (setq cur (cadr iv))))
     (if (> (- len cur) 1.0)
       (setq kept (cons (list cur len) kept)))
     (mapcar
       '(lambda (iv)
          (list (list (+ (car  a) (* (car  dir) (car iv)))
                      (+ (cadr a) (* (cadr dir) (car iv))) 0.0)
                (list (+ (car  a) (* (car  dir) (cadr iv)))
                      (+ (cadr a) (* (cadr dir) (cadr iv))) 0.0)))
       (reverse kept)))))

;; Remove from each segment the portions that fall inside any hole
;; polygon.  segs = list of (p1 p2).  Returns the surviving pieces.
(defun dsld-rpr-subtract-holes-from-segs (segs holes / parts hole out s
                                           inside filtered mid)
  (cond
    ((not holes) segs)
    (T
     (setq parts segs)
     (foreach hole holes
       (setq out '())
       (foreach s parts
         (setq inside (dsld-rpr-clip-line (car s) (cadr s) hole))
         (setq out (append out (dsld-rpr-interval-diff s inside))))
       (setq parts out))
     ;; Safety net (v1.9.7): clip-line can miss a boundary crossing when
     ;; a rafter grazes a VERTEX of a non-convex hole, leaving a whole
     ;; piece stranded INSIDE the hole -> that piece then crosses the
     ;; hole-region's own rafters (the real-roof 8/12-in-12/12 case).
     ;; Drop any surviving piece whose midpoint is still inside a hole;
     ;; a legitimately-outside rafter never has its midpoint in a hole.
     (setq filtered '())
     (foreach s parts
       (setq mid (mapcar '(lambda (a b) (/ (+ a b) 2.0)) (car s) (cadr s)))
       (setq inside nil)
       (foreach hole holes
         (if (and (not inside) (dsld-rpr-pt-in-poly mid hole))
           (setq inside T)))
       (if (not inside) (setq filtered (cons s filtered))))
     (reverse filtered))))

;; Core rafter builder: given a region, an origin point, a cardinal
;; rafter direction (0 = horizontal, pi/2 = vertical), and an o.c.
;; spacing, generate clipped LINE entities on the rafter layer.
;; Used by both the auto-generator (c:RPR) and the manual override
;; (c:RPRFIX).  Returns the list of new LINE entity names.
;;
;; Two-phase: collect all candidate segments, run bell detection, then
;; entmake only the survivors.  This preserves single short cut rafters
;; (at hip apexes) while filtering out runs of identical short rafters
;; that line up on a bell.
(defun dsld-rpr-build-rafters-at (region origin-pt rafter-dir oc-spacing /
        perp-x perp-y bb diag verts proj-list proj-min proj-max
        peak-proj n-pos n-neg i base-x base-y p-start p-end segs
        candidates excluded new rafter-list holes)
  (cond ((zerop rafter-dir) (setq perp-x 0.0 perp-y 1.0))
        (T                  (setq perp-x 1.0 perp-y 0.0)))
  ;; Smaller regions overlapping this one -- nested dormer strips AND
  ;; partial overlaps (an added area that crosses a hip/valley) -- frame
  ;; themselves so the parent's rafters break around them instead of
  ;; crossing into them (v1.9.6).
  (setq holes (dsld-rpr-rafter-clip-regions region (dsld-rpr-all-scan-polys)))
  (setq bb        (dsld-rpr-poly-bbox region))
  (setq diag      (* 1.5 (distance (car bb) (cadr bb))))
  (setq verts     (dsld-rpr-poly-vertices region))
  (setq proj-list (mapcar '(lambda (v) (+ (* (car v) perp-x)
                                          (* (cadr v) perp-y)))
                          verts))
  (setq proj-min  (apply 'min proj-list))
  (setq proj-max  (apply 'max proj-list))
  (setq peak-proj (+ (* (car  origin-pt) perp-x)
                     (* (cadr origin-pt) perp-y)))
  (setq n-pos (1+ (fix (/ (- proj-max peak-proj) oc-spacing))))
  (setq n-neg (1+ (fix (/ (- peak-proj proj-min) oc-spacing))))

  ;; Phase 1: collect every clipped segment as a candidate.
  (setq candidates '())
  (setq i (- n-neg))
  (while (<= i n-pos)
    (setq base-x  (+ (car  origin-pt) (* i oc-spacing perp-x)))
    (setq base-y  (+ (cadr origin-pt) (* i oc-spacing perp-y)))
    (setq p-start (polar (list base-x base-y 0.0) rafter-dir (- diag)))
    (setq p-end   (polar (list base-x base-y 0.0) rafter-dir   diag))
    (setq segs    (dsld-rpr-clip-line p-start p-end region))
    (setq segs    (dsld-rpr-subtract-holes-from-segs segs holes))
    (setq candidates (cons (list i segs) candidates))
    (setq i (1+ i)))
  (setq candidates (reverse candidates))

  ;; Phase 2: detect bell runs to exclude (drip-edge only).
  (setq excluded (dsld-rpr-find-bell-segs candidates rafter-dir region))

  ;; Phase 3: entmake every candidate that survived bell filtering.
  (setq rafter-list '())
  (foreach c candidates
    (foreach seg (cadr c)
      (if (not (member seg excluded))
        (progn
          (setq new (entmakex
                      (list (cons 0 "LINE")
                            (cons 8 *DSLD-RPR-RAFTER-LAYER*)
                            (cons 10 (car seg))
                            (cons 11 (cadr seg)))))
          (if new (setq rafter-list (cons new rafter-list)))))))
  (reverse rafter-list))

;; Auto rafter generation for c:RPR.
;; Direction: perpendicular to the polygon's longer bbox dimension.
;;   bbox wider than tall  -> horizontal eaves  -> vertical rafters
;;   bbox taller than wide -> vertical eaves    -> horizontal rafters
;; Peak: vertex or edge midpoint closest to the overall roof centroid.
;;   rectangular slope  -> ridge midpoint
;;   triangular hip end -> apex vertex
(defun dsld-rpr-generate-rafters (region all-polys oc-spacing /
        bb w h rafter-dir peak)
  (setq bb (dsld-rpr-poly-bbox region))
  (setq w  (abs (- (car  (cadr bb)) (car  (car bb)))))
  (setq h  (abs (- (cadr (cadr bb)) (cadr (car bb)))))
  (setq rafter-dir (if (>= w h) (/ pi 2.0) 0.0))
  (setq peak       (dsld-rpr-find-peak-by-centroid region all-polys))
  (dsld-rpr-build-rafters-at region peak rafter-dir oc-spacing))

;; Reverse-lookup: given a fill-hatch color, find the pitch that maps to it.
(defun dsld-rpr-color-to-pitch (clr / pair match)
  (foreach pair *DSLD-RPR-COLOR-MAP*
    (if (= (cdr pair) clr) (setq match (car pair))))
  match)

;; Given a HATCH entity (likely a SOLID fill), find the LWPOLYLINE on the
;; rafter layer whose interior contains the hatch's bbox center.
(defun dsld-rpr-find-polygon-for-hatch (hatch / lo hi center ss n i poly-name)
  (vl-catch-all-apply
    '(lambda ()
       (vla-GetBoundingBox (vlax-ename->vla-object hatch) 'lo 'hi)))
  (if (and lo hi)
    (progn
      (setq center (mapcar '(lambda (a b) (/ (+ a b) 2.0))
                           (vlax-safearray->list lo)
                           (vlax-safearray->list hi)))
      (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE")
                                 (cons 8 *DSLD-RPR-POLY-LAYER*))))
      (if ss
        (progn
          (setq n (sslength ss) i 0)
          (while (and (< i n) (not poly-name))
            (if (dsld-rpr-pt-in-poly center (ssname ss i))
              (setq poly-name (ssname ss i)))
            (setq i (1+ i)))))))
  poly-name)

;; Recolor the SOLID fill hatch covering region to the color mapped from
;; new-pitch.  Used when RPRFIX changes a region's pitch.
(defun dsld-rpr-recolor-fill-hatch (region new-pitch / center new-clr
                                     ss n i ent-name lo hi lo-list hi-list
                                     data done)
  (setq center  (dsld-rpr-bbox-center (dsld-rpr-poly-bbox region)))
  (setq new-clr (dsld-rpr-pitch-color new-pitch))
  (setq ss (ssget "_X" (list '(0 . "HATCH")
                             (cons 8 *DSLD-RPR-FILL-LAYER*))))
  (if ss
    (progn
      (setq n (sslength ss) i 0)
      (while (and (< i n) (not done))
        (setq ent-name (ssname ss i))
        (setq lo nil hi nil)
        (vl-catch-all-apply
          '(lambda ()
             (vla-GetBoundingBox (vlax-ename->vla-object ent-name) 'lo 'hi)))
        (if (and lo hi)
          (progn
            (setq lo-list (vlax-safearray->list lo))
            (setq hi-list (vlax-safearray->list hi))
            (if (and (>= (car  center) (car  lo-list))
                     (<= (car  center) (car  hi-list))
                     (>= (cadr center) (cadr lo-list))
                     (<= (cadr center) (cadr hi-list)))
              (progn
                (setq data (entget ent-name))
                (if (assoc 62 data)
                  (setq data (subst (cons 62 new-clr) (assoc 62 data) data))
                  (setq data (append data (list (cons 62 new-clr)))))
                (entmod data)
                (setq done T)))))
        (setq i (1+ i))))))

;; Detect an INTERIOR bell (narrow waist away from the polygon's drip
;; edge) and return its cut line (p1 p2) parallel to the rafter
;; direction.  This is the auto-split signal: 4+ short rafter segments
;; in the polygon's interior, similarly aligned and similarly sized.
;; Drip-edge bells are NOT returned here -- those are handled separately
;; by skipping their rafters in dsld-rpr-find-bell-segs.
;; Returns nil if no interior bell is found.
(defun dsld-rpr-detect-interior-bell (region oc-spacing /
        bb min-pt max-pt edge-tol w h rafter-dir perp-x perp-y
        anchor diag verts proj-list proj-min proj-max anchor-proj
        n-pos n-neg i base-x base-y p-start p-end segs candidates
        shorts seg-len mid near-edge s s-len s-mid o-len o-mid
        other mid-diff close-count cluster-mids cut-v cut-p1 cut-p2)
  (setq bb (dsld-rpr-poly-bbox region))
  (setq min-pt (car bb)) (setq max-pt (cadr bb))
  (setq edge-tol *DSLD-RPR-BELL-MAX-LEN*)
  (setq w (abs (- (car  max-pt) (car  min-pt))))
  (setq h (abs (- (cadr max-pt) (cadr min-pt))))
  (setq rafter-dir (if (>= w h) (/ pi 2.0) 0.0))
  (cond ((zerop rafter-dir) (setq perp-x 0.0 perp-y 1.0))
        (T                  (setq perp-x 1.0 perp-y 0.0)))
  (setq anchor (dsld-rpr-bbox-center bb))
  (setq diag   (* 1.5 (distance min-pt max-pt)))
  ;; Generate candidate rafter clip-segments without entmaking.
  (setq verts (dsld-rpr-poly-vertices region))
  (setq proj-list (mapcar '(lambda (v) (+ (* (car v) perp-x)
                                          (* (cadr v) perp-y)))
                          verts))
  (setq proj-min  (apply 'min proj-list))
  (setq proj-max  (apply 'max proj-list))
  (setq anchor-proj (+ (* (car anchor) perp-x) (* (cadr anchor) perp-y)))
  (setq n-pos (1+ (fix (/ (- proj-max anchor-proj) oc-spacing))))
  (setq n-neg (1+ (fix (/ (- anchor-proj proj-min) oc-spacing))))
  (setq candidates '())
  (setq i (- n-neg))
  (while (<= i n-pos)
    (setq base-x  (+ (car  anchor) (* i oc-spacing perp-x)))
    (setq base-y  (+ (cadr anchor) (* i oc-spacing perp-y)))
    (setq p-start (polar (list base-x base-y 0.0) rafter-dir (- diag)))
    (setq p-end   (polar (list base-x base-y 0.0) rafter-dir   diag))
    (setq segs    (dsld-rpr-clip-line p-start p-end region))
    (setq candidates (cons segs candidates))
    (setq i (1+ i)))
  ;; Collect ONLY the short segments NOT near a bbox edge.
  (setq shorts '())
  (foreach segs-at-i candidates
    (foreach seg segs-at-i
      (setq seg-len (distance (car seg) (cadr seg)))
      (if (< seg-len *DSLD-RPR-BELL-MAX-LEN*)
        (progn
          (setq mid (mapcar '(lambda (a b) (/ (+ a b) 2.0))
                            (car seg) (cadr seg)))
          (setq near-edge
                (or (< (- (car  mid) (car  min-pt)) edge-tol)
                    (< (- (car  max-pt) (car  mid)) edge-tol)
                    (< (- (cadr mid) (cadr min-pt)) edge-tol)
                    (< (- (cadr max-pt) (cadr mid)) edge-tol)))
          (if (not near-edge)
            (setq shorts (cons (list seg-len mid) shorts)))))))
  ;; Cluster check: keep midpoints whose peer-count >= BELL-RUN-MIN-1
  ;; (similar position along rafter direction, similar length).
  (setq cluster-mids '())
  (foreach s shorts
    (setq s-len (car s)) (setq s-mid (cadr s))
    (setq close-count 0)
    (foreach other shorts
      (if (not (eq s other))
        (progn
          (setq o-len (car other)) (setq o-mid (cadr other))
          (setq mid-diff (if (zerop rafter-dir)
                             (abs (- (car  s-mid) (car  o-mid)))
                             (abs (- (cadr s-mid) (cadr o-mid)))))
          (if (and (< mid-diff *DSLD-RPR-BELL-MID-TOL*)
                   (< (abs (- s-len o-len)) *DSLD-RPR-BELL-LEN-TOL*))
            (setq close-count (1+ close-count))))))
    (if (>= close-count (1- *DSLD-RPR-BELL-RUN-MIN*))
      (setq cluster-mids (cons s-mid cluster-mids))))
  (cond
    ((null cluster-mids) nil)
    (T
     ;; Cut line is parallel to rafter direction at the cluster's
     ;; average position along the spacing axis.
     (setq cut-v
           (/ (apply '+ (if (zerop rafter-dir)
                          (mapcar 'cadr cluster-mids)
                          (mapcar 'car  cluster-mids)))
              (length cluster-mids)))
     (cond
       ((zerop rafter-dir)
        (setq cut-p1 (list (- (car  min-pt) 100.0) cut-v 0.0))
        (setq cut-p2 (list (+ (car  max-pt) 100.0) cut-v 0.0)))
       (T
        (setq cut-p1 (list cut-v (- (cadr min-pt) 100.0) 0.0))
        (setq cut-p2 (list cut-v (+ (cadr max-pt) 100.0) 0.0))))
     (list cut-p1 cut-p2))))

;; Sign of a point relative to an oriented line p1->p2.
;;   >0 = on the left of the line, <0 = right, 0 = on the line.
(defun dsld-rpr-side-of-line (pt p1 p2 / cross)
  (setq cross (- (* (- (car  p2) (car  p1)) (- (cadr pt) (cadr p1)))
                 (* (- (cadr p2) (cadr p1)) (- (car  pt) (car  p1)))))
  (cond ((> cross 0.001)  1)
        ((< cross -0.001) -1)
        (T 0)))

;; Intersection of polygon-edge segment (e1->e2) with the INFINITE line
;; defined by (l1, l2).  Returns the intersection point or nil if the
;; edge is parallel or the intersection lies outside the segment.
(defun dsld-rpr-edge-line-intersect (e1 e2 l1 l2 /
        x1 y1 x2 y2 x3 y3 x4 y4 denom t-num pt-t)
  (setq x1 (car e1) y1 (cadr e1)
        x2 (car e2) y2 (cadr e2)
        x3 (car l1) y3 (cadr l1)
        x4 (car l2) y4 (cadr l2))
  (setq denom (- (* (- x1 x2) (- y3 y4))
                 (* (- y1 y2) (- x3 x4))))
  (if (> (abs denom) 1e-9)
    (progn
      (setq t-num (- (* (- x1 x3) (- y3 y4))
                     (* (- y1 y3) (- x3 x4))))
      (setq pt-t (/ t-num denom))
      (if (and (>= pt-t -1e-6) (<= pt-t (+ 1.0 1e-6)))
        (list (+ x1 (* pt-t (- x2 x1)))
              (+ y1 (* pt-t (- y2 y1)))
              0.0)))))

;; Split a polygon's vertex list along an infinite line.  Returns a list
;; of two vertex lists, or nil if the line doesn't cross the polygon.
;; Works for the typical case (cut line crosses exactly 2 edges).
(defun dsld-rpr-split-vertices (verts l1 l2 /
        n i v1 v2 s1 s2 side1 side2 inter)
  (setq n (length verts) i 0 side1 '() side2 '())
  (while (< i n)
    (setq v1 (nth i verts))
    (setq v2 (nth (rem (1+ i) n) verts))
    (setq s1 (dsld-rpr-side-of-line v1 l1 l2))
    (setq s2 (dsld-rpr-side-of-line v2 l1 l2))
    (cond ((> s1 0) (setq side1 (cons v1 side1)))
          ((< s1 0) (setq side2 (cons v1 side2)))
          (T        (setq side1 (cons v1 side1))
                    (setq side2 (cons v1 side2))))
    (if (and (/= s1 0) (/= s2 0)
             (/= (if (> s1 0) 1 -1) (if (> s2 0) 1 -1)))
      (progn
        (setq inter (dsld-rpr-edge-line-intersect v1 v2 l1 l2))
        (if inter
          (progn (setq side1 (cons inter side1))
                 (setq side2 (cons inter side2))))))
    (setq i (1+ i)))
  (if (and (>= (length side1) 3) (>= (length side2) 3))
    (list (reverse side1) (reverse side2))))

;; Create a new closed LWPOLYLINE from a list of (x y ...) vertices.
;; Uses the PLINE command (more robust than entmakex across BricsCAD
;; / AutoCAD versions, which differ on which DXF group codes are
;; required for LWPOLYLINE entmake).  Returns the new entity name or
;; nil on failure.
(defun dsld-rpr-make-lwpoly (vert-list layer / oldlay oldosmode oldecho
                              before after)
  (if (< (length vert-list) 3)
    nil
    (progn
      (setq oldlay    (getvar "CLAYER"))
      (setq oldosmode (getvar "OSMODE"))
      (setq oldecho   (getvar "CMDECHO"))
      ;; Stash for the command-level *error* handler: if PLINE dies
      ;; mid-stream, cleanup puts OSMODE / CLAYER / CMDECHO back.
      (dsld-rpr-stash 'osmode  oldosmode)
      (setvar "CLAYER"  layer)
      (setvar "OSMODE"  0)
      (setvar "CMDECHO" 0)
      (setq before (entlast))
      (command "_.PLINE")
      (foreach v vert-list (command (list (car v) (cadr v))))
      (command "_C")
      (setq after (entlast))
      (setvar "CMDECHO" oldecho)
      (setvar "OSMODE"  oldosmode)
      (setvar "CLAYER"  oldlay)
      (if (eq before after) nil after))))

;; Delete the SOLID fill hatch covering a polygon (looks up by bbox-center
;; containment, same logic as recolor-fill-hatch).
(defun dsld-rpr-delete-fill (region / center hatch-ss n i ent-name lo hi
                              lo-list hi-list victim)
  (setq center  (dsld-rpr-bbox-center (dsld-rpr-poly-bbox region)))
  (setq hatch-ss (ssget "_X" (list '(0 . "HATCH")
                                   (cons 8 *DSLD-RPR-FILL-LAYER*))))
  (if hatch-ss
    (progn
      (setq n (sslength hatch-ss) i 0 victim '())
      (while (< i n)
        (setq ent-name (ssname hatch-ss i))
        (setq lo nil hi nil)
        (vl-catch-all-apply
          '(lambda ()
             (vla-GetBoundingBox (vlax-ename->vla-object ent-name) 'lo 'hi)))
        (if (and lo hi)
          (progn
            (setq lo-list (vlax-safearray->list lo))
            (setq hi-list (vlax-safearray->list hi))
            (if (and (>= (car  center) (car  lo-list))
                     (<= (car  center) (car  hi-list))
                     (>= (cadr center) (cadr lo-list))
                     (<= (cadr center) (cadr hi-list)))
              (setq victim (cons ent-name victim)))))
        (setq i (1+ i)))
      (foreach v victim (entdel v)))))

;; --- Pitch tagged on the polygon as XDATA ------------------------;;
;; Storing pitch directly on the polygon avoids the failure modes of
;; fill-hatch bbox-containment lookup (wrong match for L-shaped /
;; overlapping polygons).  RPR / RPRSPLIT tag every polygon they create.

;; Tag a polygon with its pitch (real, e.g. 6.0 or 6.5) via XDATA.
;; Stores both 1040 (real, the source of truth) AND 1070 (rounded int,
;; for backward compat with v1.3.x readers that only knew 1070).
(defun dsld-rpr-tag-pitch (poly pitch / data fp)
  (regapp "DSLD_RPR")
  (setq fp (float pitch))
  (setq data (entget poly))
  ;; Drop any prior DSLD_RPR XDATA so we replace cleanly.
  (setq data (vl-remove-if
               '(lambda (x)
                  (and (= (car x) -3)
                       (assoc "DSLD_RPR" (cdr x))))
               data))
  (entmod (append data
                  (list (list -3 (list "DSLD_RPR"
                                       (cons 1040 fp)
                                       (cons 1070 (fix (+ fp 0.5)))))))))

;; Read pitch from a polygon's XDATA.  Prefers 1040 (real, current
;; format); falls back to 1070 (int) for polygons tagged by v1.3.x or
;; older.  Returns a real or nil.
(defun dsld-rpr-read-pitch (poly / xd app-data real-p int-p)
  (setq xd (cdr (assoc -3 (entget poly '("DSLD_RPR")))))
  (if xd
    (progn
      (setq app-data (cdr (assoc "DSLD_RPR" xd)))
      (cond
        ((not app-data) nil)
        ((setq real-p (cdr (assoc 1040 app-data))) real-p)
        ((setq int-p  (cdr (assoc 1070 app-data))) (float int-p))))))

;; --- RPRFIX direction/origin override, persisted as XDATA -----------;;
;; v1.8.0: an RPRFIX direction/origin used to live only in the drawn
;; rafters -- the next refresh (reactor or manual) regenerated with
;; auto direction, silently discarding the user's fix.  The override
;; now rides on the polygon: 1070 dir-code (0 = horizontal rafters,
;; 1 = vertical) + 1010 origin point.  dsld-rpr-process-single honors
;; it on every regeneration.

(defun dsld-rpr-tag-override (poly dir-code origin / data)
  (regapp "DSLD_RPR_OVR")
  (setq data (entget poly))
  (setq data (vl-remove-if
               '(lambda (x)
                  (and (= (car x) -3)
                       (assoc "DSLD_RPR_OVR" (cdr x))))
               data))
  (entmod (append data
                  (list (list -3 (list "DSLD_RPR_OVR"
                                       (cons 1070 dir-code)
                                       (cons 1010 origin)))))))

;; Returns (dir-radians origin-pt) or nil.
(defun dsld-rpr-read-override (poly / xd app-data dir-code origin)
  (setq xd (cdr (assoc -3 (entget poly '("DSLD_RPR_OVR")))))
  (if xd
    (progn
      (setq app-data (cdr (assoc "DSLD_RPR_OVR" xd)))
      (setq dir-code (cdr (assoc 1070 app-data)))
      (setq origin   (cdr (assoc 1010 app-data)))
      (if (and dir-code origin)
        (list (if (= dir-code 0) 0.0 (/ pi 2.0)) origin)))))

;; Detect a region's pitch.  Tries XDATA first (fast and exact, set by
;; RPR / RPRSPLIT at trace time); falls back to walking SOLID fill
;; hatches on the FILL layer and picking one whose bbox contains the
;; region's bbox center -- that's the legacy path used when XDATA isn't
;; present (e.g. polygons created by hand).  Returns pitch or nil.
(defun dsld-rpr-pitch-of-region (region / xd-pitch center hatch-ss n i
                                  ent-name e clr lo hi lo-list hi-list match)
  (setq xd-pitch (dsld-rpr-read-pitch region))
  (if xd-pitch
    xd-pitch
    (dsld-rpr-pitch-of-region-by-fill region)))

(defun dsld-rpr-pitch-of-region-by-fill (region / center hatch-ss n i
                                          ent-name e clr lo hi lo-list
                                          hi-list match)
  (setq center (dsld-rpr-bbox-center (dsld-rpr-poly-bbox region)))
  (setq hatch-ss (ssget "_X" (list '(0 . "HATCH")
                                   (cons 8 *DSLD-RPR-FILL-LAYER*))))
  (if hatch-ss
    (progn
      (setq n (sslength hatch-ss) i 0)
      (while (and (< i n) (not match))
        (setq ent-name (ssname hatch-ss i))
        (setq lo nil hi nil)
        (vl-catch-all-apply
          '(lambda ()
             (vla-GetBoundingBox (vlax-ename->vla-object ent-name) 'lo 'hi)))
        (if (and lo hi)
          (progn
            (setq lo-list (vlax-safearray->list lo))
            (setq hi-list (vlax-safearray->list hi))
            (if (and (>= (car center)  (car lo-list))
                     (<= (car center)  (car hi-list))
                     (>= (cadr center) (cadr lo-list))
                     (<= (cadr center) (cadr hi-list)))
              (progn
                (setq e (entget ent-name))
                (setq clr (cdr (assoc 62 e)))
                (setq match (dsld-rpr-color-to-pitch clr))))))
        (setq i (1+ i)))))
  match)

;; Delete all LINE entities (rafters) and TEXT entities (length labels and
;; pitch labels) on the SSS layers whose midpoints fall inside the given
;; polygon.  Used by RPRFIX to wipe a region before regenerating.
(defun dsld-rpr-clear-region (region / ss n i e mid victim)
  (setq victim '())
  (setq ss (ssget "_X"
             (list '(0 . "LINE,TEXT")
                   (cons 8 (strcat *DSLD-RPR-RAFTER-LAYER* ","
                                   *DSLD-RPR-LABEL-LAYER* ","
                                   *DSLD-RPR-PITCH-LBL-LAYER*)))))
  (if ss
    (progn
      (setq n (sslength ss) i 0)
      (while (< i n)
        (setq e (entget (ssname ss i)))
        (setq mid
              (cond ((= (cdr (assoc 0 e)) "LINE")
                     (mapcar '(lambda (a b) (/ (+ a b) 2.0))
                             (cdr (assoc 10 e)) (cdr (assoc 11 e))))
                    (T (cdr (assoc 10 e)))))
        (if (dsld-rpr-pt-in-poly mid region)
          (setq victim (cons (ssname ss i) victim)))
        (setq i (1+ i)))))
  (foreach v victim (entdel v))
  (length victim))

;; Label one rafter at its midpoint with rounded on-pitch length.
;; Place a length label on a line entity using a pre-rounded foot value.
;; Offsets perpendicular to the line so the line doesn't cross the text:
;;   horizontal line -> label above (+Y)
;;   vertical line   -> label right (+X)
;; Used by dsld-rpr-label-rafter and c:RPRADD (different lines, different
;; factor formulas, but same labeling style).
(defun dsld-rpr-label-line-with-len (line rounded /
                                      le sp ep mid line-ang is-horizontal
                                      offset label-pt txt-ang)
  (setq le (entget line))
  (setq sp (cdr (assoc 10 le)))
  (setq ep (cdr (assoc 11 le)))
  (setq mid (list (/ (+ (car sp) (car ep)) 2.0)
                  (/ (+ (cadr sp) (cadr ep)) 2.0)
                  0.0))
  (setq line-ang (angle sp ep))
  (setq is-horizontal (< (abs (sin line-ang)) 0.5))
  (setq offset *DSLD-RPR-LABEL-HEIGHT*)
  (setq label-pt
        (if is-horizontal
          (list (car  mid) (+ (cadr mid) offset) 0.0)
          (list (+ (car mid) offset) (cadr mid)  0.0)))
  (setq txt-ang line-ang)
  (if (or (> txt-ang (* 0.5 pi)) (< txt-ang (* -0.5 pi)))
    (setq txt-ang (+ txt-ang pi)))
  (entmake
    (list
      '(0 . "TEXT")
      (cons 8 *DSLD-RPR-LABEL-LAYER*)
      (cons 10 label-pt)
      (cons 11 label-pt)
      (cons 40 *DSLD-RPR-LABEL-HEIGHT*)
      (cons 1 (dsld-rpr-fmt-ft rounded))
      (cons 7 *DSLD-RPR-TEXT-STYLE*)
      (cons 50 txt-ang)
      (cons 72 1)                ; horiz align: center
      (cons 73 2))))             ; vert align: middle

(defun dsld-rpr-label-rafter (line pitch-rise / le sp ep len-in factor
                              len-pitch-in len-pitch-ft rounded)
  (setq le (entget line))
  (setq sp (cdr (assoc 10 le)))
  (setq ep (cdr (assoc 11 le)))
  (setq len-in (distance sp ep))
  (setq factor (sqrt (+ 1.0 (/ (* (float pitch-rise) (float pitch-rise))
                                144.0))))
  (setq len-pitch-in (* len-in factor))
  (setq len-pitch-ft (/ len-pitch-in 12.0))
  (setq rounded (dsld-rpr-round-len-ft len-pitch-ft))
  (dsld-rpr-label-line-with-len line rounded))

;; Place a "N/12" pitch label inside the region at its bbox center.
;; Flat 2D area of an LWPOLYLINE via shoelace formula.  Result in
;; SQUARE INCHES (DSLD world units).
(defun dsld-rpr-poly-area-flat (poly / verts n i v1 v2 area)
  (setq verts (dsld-rpr-poly-vertices poly))
  (setq n (length verts) i 0 area 0.0)
  (while (< i n)
    (setq v1 (nth i verts))
    (setq v2 (nth (rem (1+ i) n) verts))
    (setq area (+ area (- (* (car v1) (cadr v2))
                          (* (car v2) (cadr v1)))))
    (setq i (1+ i)))
  (* 0.5 (abs area)))

;; On-pitch (sloped) area of a polygon, given its pitch.  flat_area is
;; in square inches, output is in SQUARE FEET.
;;
;;   on-pitch_area = flat_area * sqrt(1 + (p/12)^2)
;;                 = flat_area * sqrt(1 + p^2/144)
;; On-pitch SF of a polygon minus any captured sub-regions inside it
;; (they report their own SF at their own pitch).
(defun dsld-rpr-poly-area-on-pitch-sf-net (poly pitch all-polys / sf h)
  (setq sf (dsld-rpr-poly-area-on-pitch-sf poly pitch))
  (foreach h (dsld-rpr-holes-of poly all-polys)
    (setq sf (- sf (dsld-rpr-poly-area-on-pitch-sf h pitch))))
  (max sf 0.0))

(defun dsld-rpr-poly-area-on-pitch-sf (poly pitch / a-flat factor)
  (setq a-flat (dsld-rpr-poly-area-flat poly))
  (setq factor (sqrt (+ 1.0 (/ (* (float pitch) (float pitch)) 144.0))))
  (/ (* a-flat factor) 144.0))    ; sq in -> sq ft

;; Place the region's pitch callout at its centroid (just "6/12" --
;; per-area SF totals live in the chart, not on each polygon).  Lives
;; on PITCH-LBL-LAYER which stays visible after RPRRESULT.
(defun dsld-rpr-label-pitch (region pitch / center)
  (setq center (dsld-rpr-bbox-center (dsld-rpr-poly-bbox region)))
  (entmake
    (list
      '(0 . "TEXT")
      (cons 8 *DSLD-RPR-PITCH-LBL-LAYER*)
      (cons 10 center)
      (cons 11 center)
      (cons 40 (* *DSLD-RPR-LABEL-HEIGHT* *DSLD-RPR-PITCH-LBL-MULT*))
      (cons 1 (strcat (dsld-rpr-fmt-pitch pitch) "/12"))
      (cons 7 *DSLD-RPR-TEXT-STYLE*)
      (cons 50 0.0)
      (cons 72 1)                      ; horiz center
      (cons 73 2))))                   ; vert middle

;; Color-fill the region with a SOLID hatch on the fill layer.
;;
;; v1.8.0: built via entmake instead of (command "_.-HATCH" ...).
;; Reason: this function is reachable from the vlr-command-reactor
;; callback (watch mode -> refresh -> process-single -> here), and
;; AutoCAD REJECTS any (command ...) inside a reactor callback -- the
;; refresh would wipe output and then fail to regenerate it.  entmake
;; is legal in reactor context on both CADs.  DRAWORDER (also a
;; command) was dropped; the 80% transparency keeps rafters + labels
;; readable through the fill without needing draw-order manipulation.
;; DXF association list for an entmade SOLID hatch over verts (2D point
;; list) on layer lay with ACI color clr.  Shared by dsld-rpr-fill-region
;; and the RPRDIAG live entmake test, so the diagnostic exercises the
;; EXACT list production uses.
(defun dsld-rpr-hatch-alist (verts lay clr)
  (append
    (list '(0 . "HATCH")
          '(100 . "AcDbEntity")
          (cons 8 lay)
          (cons 62 clr)
          '(100 . "AcDbHatch")
          '(10 0.0 0.0 0.0)          ; elevation point
          '(210 0.0 0.0 1.0)         ; normal
          '(2 . "SOLID")
          '(70 . 1)                  ; solid fill
          '(71 . 0)                  ; not associative
          '(91 . 1)                  ; one boundary path
          '(92 . 7)                  ; external + polyline path
          '(72 . 0)                  ; no bulges
          '(73 . 1)                  ; closed
          (cons 93 (length verts)))  ; vertex count
    (mapcar '(lambda (v) (list 10 (car v) (cadr v))) verts)
    (list '(97 . 0)                  ; no source boundary objects
          '(75 . 0)                  ; hatch style: normal
          '(76 . 1)                  ; pattern type: predefined
          '(98 . 1)                  ; one seed point
          '(10 0.0 0.0 0.0))))

;; Same solid hatch in the classic AutoCAD-proven form (AfraLisp /
;; forum canonical): 410 space marker, 47 pixel size, 3-real polyline
;; vertices.  Field RPRDIAG on AutoCAD 2025 (ACADVER 25.1s) proved the
;; minimal list above is REJECTED by real AutoCAD's entmake -- only
;; BricsCAD accepts it.
(defun dsld-rpr-hatch-alist-acad (verts lay clr)
  (append
    (list '(0 . "HATCH")
          '(100 . "AcDbEntity")
          '(410 . "Model")
          (cons 8 lay)
          (cons 62 clr)
          '(100 . "AcDbHatch")
          '(10 0.0 0.0 0.0)
          '(210 0.0 0.0 1.0)
          '(2 . "SOLID")
          '(70 . 1)
          '(71 . 0)
          '(91 . 1)
          '(92 . 7)
          '(72 . 0)
          '(73 . 1)
          (cons 93 (length verts)))
    (mapcar '(lambda (v) (list 10 (car v) (cadr v) 0.0)) verts)
    (list '(97 . 0)
          '(75 . 0)
          '(76 . 1)
          '(47 . 1.0)
          '(98 . 1)
          '(10 0.0 0.0 0.0))))

;; Last-ditch form: edge-defined boundary (92=1) with one line edge
;; (72=1) per polygon side -- the oldest, most universally accepted
;; entmake hatch layout.
(defun dsld-rpr-hatch-alist-edges (verts lay clr / n i v1 v2 edges)
  (setq n (length verts) i 0 edges '())
  (while (< i n)
    (setq v1 (nth i verts))
    (setq v2 (nth (rem (1+ i) n) verts))
    (setq edges (append edges
                        (list '(72 . 1)
                              (list 10 (car v1) (cadr v1))
                              (list 11 (car v2) (cadr v2)))))
    (setq i (1+ i)))
  (append
    (list '(0 . "HATCH")
          '(100 . "AcDbEntity")
          '(410 . "Model")
          (cons 8 lay)
          (cons 62 clr)
          '(100 . "AcDbHatch")
          '(10 0.0 0.0 0.0)
          '(210 0.0 0.0 1.0)
          '(2 . "SOLID")
          '(70 . 1)
          '(71 . 0)
          '(91 . 1)
          '(92 . 1)
          (cons 93 n))
    edges
    (list '(97 . 0)
          '(75 . 0)
          '(76 . 1)
          '(47 . 1.0)
          '(98 . 1)
          '(10 0.0 0.0 0.0))))

;; ActiveX SOLID fill via vla-AddHatch + AppendOuterLoop from a
;; throwaway boundary polyline (v1.9.4).  This is the form Lee Mac and
;; the AutoCAD forums settle on when self-defined entmake HATCH lists
;; are rejected -- it goes through the same object path AutoCAD's own
;; HATCH command uses, so it is accepted where every entmake list form
;; fails.  Pure ActiveX (no (command)) -> legal inside reactor
;; callbacks.  Non-associative, so deleting the temp boundary leaves
;; the fill intact.  Returns the hatch ename or nil.
(defun dsld-rpr-make-fill-hatch-activex (verts lay clr / doc space flat
                                          arr tmp hatch loops obj err)
  (setq err
    (vl-catch-all-apply
      '(lambda ( )
         (setq doc   (vla-get-activedocument (vlax-get-acad-object)))
         (setq space (vla-get-modelspace doc))
         ;; flat (x0 y0 x1 y1 ...) for AddLightWeightPolyline
         (setq flat '())
         (foreach v verts
           (setq flat (append flat (list (car v) (cadr v)))))
         (setq arr (vlax-make-safearray
                     vlax-vbDouble (cons 0 (1- (length flat)))))
         (vlax-safearray-fill arr flat)
         (setq tmp (vla-AddLightWeightPolyline space arr))
         (vla-put-Closed tmp :vlax-true)
         ;; PatternType 1 = predefined, assoc nil, HatchObjectType 0
         (setq hatch (vla-AddHatch space 1 "SOLID" :vlax-false 0))
         (setq loops (vlax-make-safearray vlax-vbObject '(0 . 0)))
         (vlax-safearray-put-element loops 0 tmp)
         (vla-AppendOuterLoop hatch loops)
         (vla-Evaluate hatch)
         (vla-delete tmp)                 ; non-assoc -> fill survives
         (vla-put-Layer hatch lay)
         (vla-put-Color hatch clr)
         (setq obj (vlax-vla-object->ename hatch)))))
  (cond
    ((vl-catch-all-error-p err)
     ;; clean up a stranded temp pline if we failed mid-way
     (if (and tmp (not (vl-catch-all-error-p
                         (vl-catch-all-apply 'vlax-vla-object->ename
                                             (list tmp)))))
       (vl-catch-all-apply 'vla-delete (list tmp)))
     nil)
    (T obj)))

;; entmake a SOLID hatch, laddering through the list forms until one is
;; accepted, then falling back to the ActiveX path.  Records the winning
;; form in *DSLD-RPR-HATCH-VARIANT* so RPRDIAG reports which one this
;; platform took.  On AutoCAD 2025 the entmake forms are rejected
;; (verified via field RPRDIAG) and the ActiveX rung is what actually
;; draws the fill.  Returns the ename or nil.
(defun dsld-rpr-make-fill-hatch (verts lay clr / e)
  (cond
    ((setq e (entmakex (dsld-rpr-hatch-alist verts lay clr)))
     (setq *DSLD-RPR-HATCH-VARIANT* "minimal") e)
    ((setq e (entmakex (dsld-rpr-hatch-alist-acad verts lay clr)))
     (setq *DSLD-RPR-HATCH-VARIANT* "acad-classic") e)
    ((setq e (entmakex (dsld-rpr-hatch-alist-edges verts lay clr)))
     (setq *DSLD-RPR-HATCH-VARIANT* "edge-list") e)
    ((setq e (dsld-rpr-make-fill-hatch-activex verts lay clr))
     (setq *DSLD-RPR-HATCH-VARIANT* "activex") e)))

(defun dsld-rpr-fill-region (region pitch / clr verts n after)
  (setq clr   (dsld-rpr-pitch-color pitch))
  (setq verts (dsld-rpr-poly-vertices region))
  (setq n     (length verts))
  (cond
    ((< n 3) nil)
    (T
     (setq after
       (dsld-rpr-make-fill-hatch verts *DSLD-RPR-FILL-LAYER* clr))
     (cond
       ((not after)
        ;; entmakex silently refused the list.  Count it so RPRDIAG can
        ;; surface it from the field (AutoCAD entmake is stricter than
        ;; BricsCAD -- a refused hatch here is invisible otherwise).
        (setq *DSLD-RPR-FILL-FAILS*
              (1+ (cond (*DSLD-RPR-FILL-FAILS*) (0))))
        nil)
       (after
        ;; Transparency so rafters/labels read clearly through fill.
        (vl-catch-all-apply
          '(lambda ()
             (vla-put-EntityTransparency
               (vlax-ename->vla-object after)
               (itoa *DSLD-RPR-FILL-TRANSP*))))
        ;; Push the fill BEHIND everything (v1.9.1).  Without this the
        ;; entmade hatch is the topmost entity, so clicking a region
        ;; grabbed the HATCH instead of the boundary polyline -- users
        ;; couldn't grip-drag boundary vertices at all.  DRAWORDER is
        ;; a command, so it only runs outside reactor context; fills
        ;; created BY a reactor refresh stay unordered (they're hidden
        ;; in the finished view anyway, and RPRSHOW re-orders them).
        (if (not *DSLD-RPR-REFRESHING*)
          (vl-catch-all-apply
            '(lambda () (command "_.DRAWORDER" after "" "_B"))))
        ;; Optional group binding (opt-in; never inside a reactor --
        ;; -GROUP is a command).  Off by default because AutoCAD blocks
        ;; vertex grips on grouped polylines.
        (if (and *DSLD-RPR-USE-GROUPS* (not *DSLD-RPR-REFRESHING*))
          (dsld-rpr-group-entities (list region after)))
        ;; Force a repaint of just this hatch.  Some AutoCAD seats leave
        ;; an entmade/AddHatch solid unpainted until the next regen;
        ;; (entupd) is reactor-safe (unlike REGEN, which is a command).
        (vl-catch-all-apply '(lambda () (entupd after)))
        after)))))

;; Process a single polygon: fill, label pitch, generate rafters with
;; pitch-corrected length labels.  Refreshes its own all-polys list so
;; entities deleted by an earlier auto-split don't poison the centroid.
(defun dsld-rpr-process-single (region pitch oc-spacing /
                                 ss all-polys-fresh rafters ovr)
  (dsld-rpr-dbg "  ps: enter")
  (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE")
                             (cons 8 *DSLD-RPR-POLY-LAYER*))))
  (setq all-polys-fresh (dsld-rpr-ss->list ss))
  (dsld-rpr-fill-region  region pitch)
  (dsld-rpr-dbg "  ps: fill ok")
  (dsld-rpr-label-pitch  region pitch)
  (dsld-rpr-dbg "  ps: label ok")
  ;; Honor a persisted RPRFIX direction/origin override (v1.8.0) so
  ;; refreshes stop silently reverting the user's manual correction.
  (setq ovr (dsld-rpr-read-override region))
  (dsld-rpr-dbg (strcat "  ps: ovr=" (if ovr "T" "nil")))
  (setq rafters
        (if ovr
          (dsld-rpr-build-rafters-at region (cadr ovr) (car ovr)
                                      oc-spacing)
          (dsld-rpr-generate-rafters region all-polys-fresh oc-spacing)))
  (dsld-rpr-dbg (strcat "  ps: rafters=" (itoa (length rafters))))
  (foreach rl rafters (dsld-rpr-label-rafter rl pitch))
  (length rafters))

;; Recursive processor: detect interior bell -> auto-split -> recurse on
;; each sub-polygon.  Falls through to single-polygon processing when
;; no interior bell is found.
(defun dsld-rpr-process-polygon (region pitch oc-spacing /
                                  cut-line new-vert-lists sub-poly n-rafters)
  (setq cut-line (dsld-rpr-detect-interior-bell region oc-spacing))
  (cond
    (cut-line
     (setq new-vert-lists
           (dsld-rpr-split-vertices (dsld-rpr-poly-vertices region)
                                     (car cut-line) (cadr cut-line)))
     (cond
       (new-vert-lists
        (princ " interior bell -> splitting.")
        (entdel region)
        (foreach vlist new-vert-lists
          (setq sub-poly
                (dsld-rpr-make-lwpoly vlist *DSLD-RPR-POLY-LAYER*))
          (if sub-poly
            (progn
              (dsld-rpr-tint-poly sub-poly)
              (dsld-rpr-process-polygon sub-poly pitch oc-spacing)))))
       (T
        ;; Detection succeeded but split produced degenerate result --
        ;; process as a single polygon.
        (setq n-rafters (dsld-rpr-process-single region pitch oc-spacing))
        (princ (strcat " " (itoa n-rafters) " rafters.")))))
    (T
     (setq n-rafters (dsld-rpr-process-single region pitch oc-spacing))
     (princ (strcat " " (itoa n-rafters) " rafters.")))))

;; Overlap test for two closed polygons.  True iff one polygon's bbox-
;; center is interior to the other.  Adjacent polygons that share an
;; edge or a vertex are NOT flagged (the previous vertex/edge-intersect
;; test triggered on shared endpoints, which produced false positives
;; for nearly every pair of adjacent roof sections).  This catches the
;; typical roof-overlap case (dormer or similar fully-or-mostly inside
;; another region) and ignores edge-sharing.
(defun dsld-rpr-polys-overlap (a b / ca cb)
  (setq ca (dsld-rpr-bbox-center (dsld-rpr-poly-bbox a)))
  (setq cb (dsld-rpr-bbox-center (dsld-rpr-poly-bbox b)))
  (or (dsld-rpr-pt-in-poly ca b)
      (dsld-rpr-pt-in-poly cb a)))

;; Returns flat list of polygon entity names that overlap with at least
;; one other in the input list.
(defun dsld-rpr-find-overlapping-polys (polys / n i j a b result)
  (setq result '())
  (setq n (length polys))
  (setq i 0)
  (while (< i n)
    (setq a (nth i polys))
    (setq j (1+ i))
    (while (< j n)
      (setq b (nth j polys))
      (if (dsld-rpr-polys-overlap a b)
        (progn
          (if (not (member a result)) (setq result (cons a result)))
          (if (not (member b result)) (setq result (cons b result)))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  result)

;; Override entity color and lineweight via ActiveX -- more reliable
;; than entmod-based DXF manipulation in BricsCAD.  Wrapped in
;; vl-catch-all-apply so a failure on one entity doesn't abort.
(defun dsld-rpr-set-color (ent color)
  (vl-catch-all-apply
    '(lambda ()
       (vlax-put-property (vlax-ename->vla-object ent) 'Color color))))

(defun dsld-rpr-set-lineweight (ent lwt)
  (vl-catch-all-apply
    '(lambda ()
       (vlax-put-property (vlax-ename->vla-object ent) 'Lineweight lwt))))

;; Pull next color from cycling palette and advance the index.  Used to
;; tint each polygon outline distinctly so adjacent regions don't blur
;; into each other along shared edges.
(defun dsld-rpr-next-outline-color ( / clr)
  (setq clr (nth (rem *DSLD-RPR-OUTLINE-CLR-IDX*
                       (length *DSLD-RPR-OUTLINE-COLORS*))
                  *DSLD-RPR-OUTLINE-COLORS*))
  (setq *DSLD-RPR-OUTLINE-CLR-IDX* (1+ *DSLD-RPR-OUTLINE-CLR-IDX*))
  clr)

;; Convenience: tint a freshly-created polygon outline with the next
;; cycling color.  Returns the entity for chaining.
(defun dsld-rpr-tint-poly (ent)
  (if ent (dsld-rpr-set-color ent (dsld-rpr-next-outline-color)))
  ent)

;; Make sure GROUP selection (PICKSTYLE bit 1) is enabled so that
;; clicking a polygon outline OR its fill hatch selects both at once.
(defun dsld-rpr-ensure-pickstyle ( / cur)
  (setq cur (getvar "PICKSTYLE"))
  (if (zerop (logand cur 1))
    (setvar "PICKSTYLE" (logior cur 1))))

;; Bind a list of entities into a named Group via the command-line
;; -GROUP form.  Picking any one selects them all when PICKSTYLE bit 1
;; is on.  Wrapped in vl-catch-all-apply so a hiccup on one group
;; doesn't abort the larger routine.  Returns the group name on
;; success, nil on failure.
;;
;; -GROUP prompt sequence (consistent across AutoCAD and BricsCAD):
;;   Option       -> _C   (Create)
;;   Group name   -> <name>
;;   Description  -> <empty>
;;   Select objs  -> <ent>...<ent>
;;   Done         -> <empty>
(defun dsld-rpr-group-entities (ents / oldecho name)
  (cond
    ((or (null ents) (null (cdr ents))) nil)
    (T
     (setq oldecho (getvar "CMDECHO"))
     (setvar "CMDECHO" 0)
     (setq *DSLD-RPR-GRP-IDX* (1+ *DSLD-RPR-GRP-IDX*))
     (setq name (strcat "RPR_GRP_" (itoa *DSLD-RPR-GRP-IDX*)))
     (vl-catch-all-apply
       '(lambda ()
          (command "_.-GROUP" "_C" name "")
          (foreach e ents (command e))
          (command "")))
     (setvar "CMDECHO" oldecho)
     name)))

;;-----------------------------------------------------------------------;;
;; Hip / Ridge / Valley callouts -- placed on shared edges between
;; adjacent roof polygons.  Length is shown in a circle bubble.
;; Cardinal-axis lines (horizontal or vertical) are treated as ridges
;; (factor = 1.0 since a ridge is horizontal in 3D).  Diagonal lines
;; are treated as hip/valley using the unequal-pitch corner formula.
;;-----------------------------------------------------------------------;;

;; Place a length callout: a circle bubble offset perpendicular from
;; the edge midpoint (so the line passes BESIDE, not THROUGH, the
;; bubble), with the rounded foot value as TEXT inside.  Offset
;; direction is chosen to push the bubble toward ref-pt (typically the
;; overall roof centroid) so callouts end up on the roof side rather
;; than out in space.  Skips callouts whose rounded length is <= 0
;; (degenerate near-coincident shared edges that produced empty bubbles).
(defun dsld-rpr-place-circle-callout (v1 v2 rounded ref-pt /
                                       mid text-h radius ev-x ev-y len
                                       pv-x pv-y dot-prod sign
                                       offset-dist circle-pt)
  (cond
    ((or (null rounded) (<= rounded 0)) nil)
    (T
     (setq mid    (mapcar '(lambda (a b) (/ (+ a b) 2.0)) v1 v2))
     (setq text-h (* *DSLD-RPR-LABEL-HEIGHT* *DSLD-RPR-CALLOUT-TEXT-MULT*))
     (setq radius (* text-h *DSLD-RPR-CALLOUT-RADIUS-MULT*))
     (setq ev-x   (- (car  v2) (car  v1)))
     (setq ev-y   (- (cadr v2) (cadr v1)))
     (setq len    (sqrt (+ (* ev-x ev-x) (* ev-y ev-y))))
     (cond
       ((zerop len) nil)
       (T
        ;; Perpendicular CCW unit vector: rotate edge 90 deg CCW.
        (setq pv-x (/ (- ev-y) len))
        (setq pv-y (/ ev-x  len))
        ;; Side selection: dot the perpendicular with (ref-pt - mid).
        ;; Positive => ref-pt is on the +pv side; flip to that side.
        (setq dot-prod
              (if ref-pt
                (+ (* pv-x (- (car  ref-pt) (car  mid)))
                   (* pv-y (- (cadr ref-pt) (cadr mid))))
                1.0))
        (setq sign (if (minusp dot-prod) -1.0 1.0))
        ;; Offset by ~2.5x bubble radius so the edge clears the bubble.
        (setq offset-dist (* 2.5 radius))
        (setq circle-pt
              (list (+ (car  mid) (* sign pv-x offset-dist))
                    (+ (cadr mid) (* sign pv-y offset-dist))
                    0.0))
        (entmake (list (cons 0 "CIRCLE")
                       (cons 8 *DSLD-RPR-LABEL-LAYER*)
                       (cons 10 circle-pt)
                       (cons 40 radius)))
        (entmake (list '(0 . "TEXT")
                       (cons 8 *DSLD-RPR-LABEL-LAYER*)
                       (cons 10 circle-pt) (cons 11 circle-pt)
                       (cons 40 text-h)
                       (cons 1 (dsld-rpr-fmt-ft rounded))
                       (cons 7 *DSLD-RPR-TEXT-STYLE*)
                       (cons 50 0.0)
                       (cons 72 1) (cons 73 2))))))))

;; Collinear-overlap test between segment (a1 a2) and segment (b1 b2).
;; Returns (p q) -- the overlapping portion expressed on segment A --
;; when B is collinear with A (both endpoints within tol of A's
;; infinite line) and the projected overlap is at least min-len long.
;; nil otherwise.  This replaces naive endpoint-pair matching, which
;; missed shared edges as soon as one polygon had an extra vertex along
;; the edge (routine grip-edit fallout) and double-counted slivers.
(defun dsld-rpr-seg-overlap (a1 a2 b1 b2 tol min-len /
                              ax ay ux uy len d1 d2 t1 t2 tb-lo tb-hi
                              lo hi)
  (setq ax (car a1) ay (cadr a1))
  (setq ux (- (car a2) ax) uy (- (cadr a2) ay))
  (setq len (sqrt (+ (* ux ux) (* uy uy))))
  (cond
    ((< len 0.001) nil)
    (T
     (setq ux (/ ux len) uy (/ uy len))
     ;; Perpendicular distances of b1/b2 from A's infinite line.
     (setq d1 (abs (- (* ux (- (cadr b1) ay)) (* uy (- (car b1) ax)))))
     (setq d2 (abs (- (* ux (- (cadr b2) ay)) (* uy (- (car b2) ax)))))
     (cond
       ((or (> d1 tol) (> d2 tol)) nil)   ; not collinear
       (T
        ;; Parameters of b1/b2 along A's axis.
        (setq t1 (+ (* ux (- (car b1) ax)) (* uy (- (cadr b1) ay))))
        (setq t2 (+ (* ux (- (car b2) ax)) (* uy (- (cadr b2) ay))))
        (setq tb-lo (min t1 t2) tb-hi (max t1 t2))
        (setq lo (max 0.0 tb-lo) hi (min len tb-hi))
        (cond
          ((< (- hi lo) min-len) nil)      ; overlap too short
          (T
           (list (list (+ ax (* ux lo)) (+ ay (* uy lo)))
                 (list (+ ax (* ux hi)) (+ ay (* uy hi)))))))))))

;; Find every edge run shared between polygons poly-a and poly-b.
;; v1.8.0: collinear-overlap detection (tolerant of extra vertices
;; along a shared edge, which grip-edits routinely introduce), plus
;; midpoint-based dedup so the same physical ridge isn't emitted twice.
;; Overlaps shorter than 12" are ignored (no callout that small).
;; Returns list of (v1 v2) pairs.
(defun dsld-rpr-find-shared-edges-between (poly-a poly-b /
                                            tol verts-a verts-b
                                            na nb i j v1a v2a v1b v2b
                                            ov mid dup m shared mids)
  ;; v1.9.11: pairing uses the looser EDGE-PAIR tolerance so a small
  ;; grip-nudge of one region doesn't silently kill the callout.
  (setq tol (max *DSLD-RPR-GAP-TOL* *DSLD-RPR-EDGE-PAIR-TOL*))
  (setq verts-a (dsld-rpr-poly-vertices poly-a))
  (setq verts-b (dsld-rpr-poly-vertices poly-b))
  (setq na (length verts-a) nb (length verts-b))
  (setq shared '() mids '())
  (setq i 0)
  (while (< i na)
    (setq v1a (nth i verts-a))
    (setq v2a (nth (rem (1+ i) na) verts-a))
    (setq j 0)
    (while (< j nb)
      (setq v1b (nth j verts-b))
      (setq v2b (nth (rem (1+ j) nb) verts-b))
      (setq ov (dsld-rpr-seg-overlap v1a v2a v1b v2b tol 12.0))
      (cond
        (ov
         (setq mid (list (/ (+ (car  (car ov)) (car  (cadr ov))) 2.0)
                         (/ (+ (cadr (car ov)) (cadr (cadr ov))) 2.0)))
         (setq dup nil)
         (foreach m mids
           (if (< (distance mid m) 6.0) (setq dup T)))
         (cond
           ((not dup)
            (setq mids   (cons mid mids))
            (setq shared (cons ov shared))))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  shared)

;; Place a callout on one shared edge.  Picks ridge factor (1.0) if the
;; edge is within 5 degrees of a cardinal axis, otherwise hip/valley
;; factor with both pitches.  ref-pt is forwarded to callout placement
;; so the bubble sits on the roof side of the edge.
(defun dsld-rpr-label-shared-edge (v1 v2 pa pb ref-pt /
                                    len-flat ang-rad ang-deg is-cardinal
                                    fpa fpb factor len-true len-true-ft
                                    rounded)
  (setq len-flat (distance v1 v2))
  ;; Angle folded into [0, 90] so we can test "near horizontal OR near
  ;; vertical" with one comparison.  Without folding, an angle of 140
  ;; degrees would test as 140 which falsely matches >85 = "vertical".
  (setq ang-rad (rem (abs (angle v1 v2)) pi))
  (setq ang-deg (* (/ ang-rad pi) 180.0))
  (if (> ang-deg 90.0) (setq ang-deg (- 180.0 ang-deg)))
  (setq is-cardinal (or (<= ang-deg  5.0)
                        (>= ang-deg 85.0)))
  (setq fpa (float pa)) (setq fpb (float pb))
  (cond
    (is-cardinal
     (setq factor 1.0))                     ; Ridge -- horizontal in 3D
    (T                                      ; Hip / Valley
     (setq factor (sqrt (+ 1.0
                           (/ (* (* fpa fpa) (* fpb fpb))
                              (* 144.0 (+ (* fpa fpa) (* fpb fpb)))))))))
  (setq len-true    (* len-flat factor))
  (setq len-true-ft (/ len-true 12.0))
  (setq rounded     (dsld-rpr-round-len-ft len-true-ft))
  (dsld-rpr-place-circle-callout v1 v2 rounded ref-pt))

;; Walk every UNIQUE pair of polygons and label all shared edges between
;; them.  Pair iteration uses i<j so each edge is labeled once.
;; Polygons whose pitch can't be detected are skipped.  Computes the
;; overall roof centroid once and threads it down so each callout
;; bubble offsets toward the roof body (away from the perimeter).
;; v1.9.6: EACH region pair is wrapped in its own catch.  Before, one
;; bad pair (a degenerate edge on some complex traced polygon, say)
;; threw out of the whole loop -- and because refresh wipes ALL H/R/V
;; before regenerating, a single failure made EVERY callout vanish on a
;; live edit ("H/R/V disappears when I alter the area").  Now a bad pair
;; is recorded and skipped; every other callout still regenerates.
(defun dsld-rpr-label-all-shared-edges (all-polys /
                                         n i j pa pb pa-pitch pb-pitch
                                         labeled centroid err fails
                                         parts cl)
  (setq labeled 0 fails 0)
  ;; v1.9.14: shared edges double as the junction-node source for
  ;; dsld-rpr-add-junction-rafters -- collect (v1 v2 pa pb) records
  (setq *DSLD-RPR-SHARED-EDGES* '())
  ;; v1.9.8: callout bubbles offset toward the centroid of the region's
  ;; OWN house (adjacency cluster), not the average across every plan
  ;; copy in the scan window (which sat in empty space between houses
  ;; and flipped bubbles to the wrong side).
  (setq parts
        (vl-catch-all-apply
          '(lambda () (dsld-rpr-partition-clusters all-polys))))
  (if (vl-catch-all-error-p parts) (setq parts nil))
  (setq n (length all-polys) i 0)
  (while (< i n)
    (setq pa       (nth i all-polys))
    (setq centroid nil)
    (foreach cl parts
      (if (and (not centroid) (member pa cl))
        (setq centroid
              (vl-catch-all-apply
                '(lambda () (dsld-rpr-overall-centroid cl))))))
    (if (vl-catch-all-error-p centroid) (setq centroid nil))
    (setq pa-pitch (vl-catch-all-apply
                     '(lambda () (dsld-rpr-pitch-of-region pa))))
    (if (vl-catch-all-error-p pa-pitch) (setq pa-pitch nil))
    (setq j (1+ i))
    (while (< j n)
      (setq pb       (nth j all-polys))
      (setq pb-pitch (vl-catch-all-apply
                       '(lambda () (dsld-rpr-pitch-of-region pb))))
      (if (vl-catch-all-error-p pb-pitch) (setq pb-pitch nil))
      (if (and pa-pitch pb-pitch)
        (progn
          (setq err
            (vl-catch-all-apply
              '(lambda ( / edges edge)
                 (setq edges (dsld-rpr-find-shared-edges-between pa pb))
                 (foreach edge edges
                   (setq *DSLD-RPR-SHARED-EDGES*
                         (cons (list (car edge) (cadr edge) pa pb)
                               *DSLD-RPR-SHARED-EDGES*))
                   (dsld-rpr-label-shared-edge (car edge) (cadr edge)
                                                pa-pitch pb-pitch centroid)
                   (setq labeled (1+ labeled))))))
          (if (vl-catch-all-error-p err)
            (progn
              (setq fails (1+ fails))
              (setq *DSLD-RPR-LAST-REFRESH-ERR*
                    (strcat "shared-edge pair: "
                            (vl-catch-all-error-message err)))))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  labeled)

;;-----------------------------------------------------------------------;;
;; Junction rafters (v1.9.14)
;;-----------------------------------------------------------------------;;
;; Framing carries a rafter at every point where hips/valleys meet a
;; ridge or each other.  The endpoints of the shared edges collected by
;; dsld-rpr-label-all-shared-edges ARE those junction nodes.  The 24"
;; grid hits some by luck (the origin sits on the region's peak); this
;; pass adds a rafter through every node the grid missed.

;; Region's rafter direction, override-aware (same choice the
;; generators make): 0 = horizontal, pi/2 = vertical.
(defun dsld-rpr-region-rafter-dir (region / ovr bb w h)
  (setq ovr (dsld-rpr-read-override region))
  (cond
    (ovr (if (= (fix (car ovr)) 0) 0.0 (/ pi 2.0)))
    (T
     (setq bb (dsld-rpr-poly-bbox region))
     (setq w (abs (- (car  (cadr bb)) (car  (car bb)))))
     (setq h (abs (- (cadr (cadr bb)) (cadr (car bb)))))
     (if (>= w h) (/ pi 2.0) 0.0))))

;; Add a rafter through every junction node inside/on each region that
;; the existing grid does not already cover.  Returns count added.
(defun dsld-rpr-add-junction-rafters (all-polys / added region pitch dir
        vert bb diag holes have nodes nd rec perp-c ex skip verts n j
        a b edeg ndeg pieces best seg new lines e mid)
  (setq added 0)
  (foreach region all-polys
    (setq pitch (dsld-rpr-read-pitch region))
    (cond
      ((not pitch) nil)
      (T
       (setq dir  (dsld-rpr-region-rafter-dir region))
       (setq vert (> dir 0.1))                 ; T = vertical rafters
       (setq bb   (dsld-rpr-poly-bbox region))
       (setq diag (* 1.5 (distance (car bb) (cadr bb))))
       (setq holes (dsld-rpr-rafter-clip-regions region all-polys))
       ;; perp coords of the rafters this region already has
       (setq have '())
       (setq lines (dsld-rpr-ents-in-bbox "LINE" *DSLD-RPR-RAFTER-LAYER*
                                           (car bb) (cadr bb) 1.0))
       (foreach e lines
         (setq mid (dsld-rpr-line-mid e))
         (if (dsld-rpr-pt-in-poly mid region)
           (setq have (cons (if vert (car mid) (cadr mid)) have))))
       ;; every junction node = shared-edge endpoint near this region
       (setq nodes '())
       (foreach rec *DSLD-RPR-SHARED-EDGES*
         (foreach nd (list (car rec) (cadr rec))
           (if (and (>= (car  nd) (- (car  (car bb)) 1.0))
                    (<= (car  nd) (+ (car  (cadr bb)) 1.0))
                    (>= (cadr nd) (- (cadr (car bb)) 1.0))
                    (<= (cadr nd) (+ (cadr (cadr bb)) 1.0)))
             (setq nodes (cons nd nodes)))))
       (foreach nd nodes
         (setq perp-c (if vert (car nd) (cadr nd)))
         ;; grid already covers this node?
         (setq ex nil)
         (foreach hv have
           (if (< (abs (- hv perp-c)) 2.0) (setq ex T)))
         ;; node on/in the region?  (inside, or within 1" of an edge)
         (setq skip ex)
         (cond
           ((not skip)
            (setq verts (dsld-rpr-poly-vertices region))
            (setq n (length verts) j 0 edeg nil)
            (setq ndeg (if (dsld-rpr-pt-in-poly nd region) T nil))
            (while (< j n)
              (setq a (nth j verts) b (nth (rem (1+ j) n) verts))
              (if (< (distance nd (dsld-rpr-project-to-seg nd a b)) 1.0)
                (progn
                  (setq ndeg T)
                  ;; boundary edge PARALLEL to the rafter direction:
                  ;; the junction rafter would lie on the boundary
                  (setq edeg (* 180.0 (/ (rem (abs (angle a b)) pi) pi)))
                  (if (> edeg 90.0) (setq edeg (- 180.0 edeg)))
                  (if (if vert (> edeg 85.0) (< edeg 5.0))
                    (setq skip T))))
              (setq j (1+ j)))
            (if (not ndeg) (setq skip T))))
         (cond
           ((not skip)
            ;; clipped scanline through the node, holes subtracted
            (setq pieces (dsld-rpr-clip-line
                           (polar (list (car nd) (cadr nd) 0.0) dir (- diag))
                           (polar (list (car nd) (cadr nd) 0.0) dir diag)
                           region))
            (setq pieces (dsld-rpr-subtract-holes-from-segs pieces holes))
            ;; keep the piece the node sits on
            (setq best nil)
            (foreach seg pieces
              (if (and (not best)
                       (< (distance nd (dsld-rpr-project-to-seg
                                         nd (car seg) (cadr seg))) 1.0))
                (setq best seg)))
            (cond
              ((and best (> (distance (car best) (cadr best)) 6.0))
               (setq new (entmakex
                           (list (cons 0 "LINE")
                                 (cons 8 *DSLD-RPR-RAFTER-LAYER*)
                                 (cons 10 (car best))
                                 (cons 11 (cadr best)))))
               (cond
                 (new
                  (dsld-rpr-label-rafter new pitch)
                  (setq have (cons perp-c have))
                  (setq added (1+ added)))))))))
       )))
  (if (> added 0)
    (dsld-rpr-dbg (strcat "junction rafters added: " (itoa added))))
  added)

;;-----------------------------------------------------------------------;;
;; Count chart  (rafters / under-8' / H-R-V) -- rendered upper-right
;; of the RPR scan bbox so the user sees a quick takeoff next to the
;; drawing.  Lives on its own CHART-LAYER so it can be toggled off
;; independently of rafters/labels.
;;-----------------------------------------------------------------------;;

;; Midpoint of a LINE entity.
(defun dsld-rpr-line-mid (ent / e p1 p2)
  (setq e (entget ent))
  (setq p1 (cdr (assoc 10 e)))
  (setq p2 (cdr (assoc 11 e)))
  (list (/ (+ (car  p1) (car  p2)) 2.0)
        (/ (+ (cadr p1) (cadr p2)) 2.0)
        0.0))

;; Length of a LINE entity in drawing units (inches in DSLD).
(defun dsld-rpr-line-length (ent / e p1 p2)
  (setq e (entget ent))
  (setq p1 (cdr (assoc 10 e)))
  (setq p2 (cdr (assoc 11 e)))
  (distance p1 p2))

;; Given a point and a list of polygon enames, return the polygon whose
;; interior contains the point, or nil.
(defun dsld-rpr-find-poly-at-pt (pt polys / found)
  (foreach p polys
    (if (and (not found) (dsld-rpr-pt-in-poly pt p))
      (setq found p)))
  found)

;; Increment the count for a key in an alist.  Returns the new alist.
(defun dsld-rpr-counts-inc (counts key / hit)
  (setq hit (assoc key counts))
  (cond
    (hit (subst (cons key (1+ (cdr hit))) hit counts))
    (T   (cons (cons key 1) counts))))

;; Recompute every H/R/V edge length (in feet, on-pitch) without
;; drawing anything.  Mirrors dsld-rpr-label-all-shared-edges geometry
;; logic.  Used by the chart to bucket H/R/V members by length.
;; Returns a flat list of real feet values.
(defun dsld-rpr-collect-hrv-lengths-ft (all-polys /
                                          n i j pa pb pa-pitch pb-pitch
                                          edges edge result
                                          len-flat ang-rad ang-deg is-cardinal
                                          fpa fpb factor len-true-ft)
  (setq result '())
  (setq n (length all-polys) i 0)
  (while (< i n)
    (setq pa       (nth i all-polys))
    (setq pa-pitch (dsld-rpr-pitch-of-region pa))
    (setq j (1+ i))
    (while (< j n)
      (setq pb       (nth j all-polys))
      (setq pb-pitch (dsld-rpr-pitch-of-region pb))
      (if (and pa-pitch pb-pitch)
        (progn
          (setq edges (dsld-rpr-find-shared-edges-between pa pb))
          (foreach edge edges
            (setq len-flat (distance (car edge) (cadr edge)))
            (setq ang-rad (rem (abs (angle (car edge) (cadr edge))) pi))
            (setq ang-deg (* (/ ang-rad pi) 180.0))
            (if (> ang-deg 90.0) (setq ang-deg (- 180.0 ang-deg)))
            (setq is-cardinal (or (<= ang-deg 5.0) (>= ang-deg 85.0)))
            (setq fpa (float pa-pitch) fpb (float pb-pitch))
            (setq factor
                  (cond
                    (is-cardinal 1.0)
                    (T (sqrt (+ 1.0
                                (/ (* fpa fpa fpb fpb)
                                   (* 144.0 (+ (* fpa fpa) (* fpb fpb)))))))))
            (setq len-true-ft (/ (* len-flat factor) 12.0))
            (if (> len-true-ft 0.001)
              (setq result (cons len-true-ft result))))))
      (setq j (1+ j)))
    (setq i (1+ i)))
  result)

;; Bucket a list of raw feet values per the DSLD rounding rule:
;;   rounded < 8  -> add raw ft to random-LF
;;   rounded >= 8 -> ++bucket[rounded]
;; Returns (random-lf . buckets) where buckets = alist (rounded-ft . count).
(defun dsld-rpr-bucket-lengths (lengths-ft / random-lf buckets ft rounded)
  (setq random-lf 0.0 buckets '())
  (foreach ft lengths-ft
    (setq rounded (dsld-rpr-round-len-ft ft))
    (cond
      ((not rounded) nil)
      ((< rounded 8)
       (setq random-lf (+ random-lf ft)))
      (T
       (setq buckets (dsld-rpr-counts-inc buckets rounded)))))
  (cons random-lf buckets))

;; Walk all RPR-generated geometry inside the bbox and tally:
;;   (:rafter-buckets . alist len->count)   -- rafters rounded >= 8'
;;   (:rafter-random-lf . real)             -- sum of raw ft, rounded < 8'
;;   (:hrv-buckets . alist len->count)      -- H/R/V rounded >= 8'
;;   (:hrv-random-lf . real)                -- sum of raw ft, rounded < 8'
;;   (:area-by-pitch . alist pitch->sf)     -- per-pitch on-pitch SF totals
;;   (:total-sf . real)                     -- grand total on-pitch SF
(defun dsld-rpr-collect-counts (p1 p2 / lines polys
                                  line mid poly pitch raw-len ft
                                  rafter-lens hrv-lens
                                  rafter-bucket-pair hrv-bucket-pair
                                  area-by-pitch poly-pitch poly-sf hit total-sf)
  ;; View-independent selection (v1.8.0) -- ssget "_C" only saw what
  ;; was on screen, so charts computed while zoomed in were wrong.
  (setq lines (dsld-rpr-ents-in-bbox "LINE" *DSLD-RPR-RAFTER-LAYER*
                                      p1 p2 0.0))
  (setq polys (dsld-rpr-ents-in-bbox "LWPOLYLINE" *DSLD-RPR-POLY-LAYER*
                                      p1 p2 0.0))
  ;; --- rafter lengths ---
  (setq rafter-lens '())
  (foreach line lines
    (setq mid  (dsld-rpr-line-mid line))
    (setq poly (dsld-rpr-find-poly-at-pt mid polys))
    (cond
      (poly
       (setq pitch (dsld-rpr-read-pitch poly))
       (cond
         (pitch
          (setq raw-len (dsld-rpr-line-length line))
          (setq ft (/ (* raw-len
                         (sqrt (+ 1.0 (/ (* pitch pitch) 144.0))))
                      12.0))
          (setq rafter-lens (cons ft rafter-lens)))))))
  (setq rafter-bucket-pair (dsld-rpr-bucket-lengths rafter-lens))
  ;; --- H/R/V lengths ---
  (setq hrv-lens (dsld-rpr-collect-hrv-lengths-ft polys))
  (setq hrv-bucket-pair (dsld-rpr-bucket-lengths hrv-lens))
  ;; --- on-pitch area per pitch + grand total ---
  ;; v1.9.3: a parent region's SF excludes captured sub-regions inside
  ;; it (dormer strips report their own SF at their own pitch --
  ;; counting the footprint twice inflated the takeoff).
  (setq area-by-pitch '() total-sf 0.0)
  (foreach p polys
    (setq poly-pitch (dsld-rpr-read-pitch p))
    (cond
      (poly-pitch
       (setq poly-sf (dsld-rpr-poly-area-on-pitch-sf-net p poly-pitch polys))
       (setq total-sf (+ total-sf poly-sf))
       (setq hit (assoc poly-pitch area-by-pitch))
       (cond
         (hit (setq area-by-pitch
                    (subst (cons poly-pitch (+ (cdr hit) poly-sf))
                           hit area-by-pitch)))
         (T   (setq area-by-pitch
                    (cons (cons poly-pitch poly-sf) area-by-pitch)))))))
  ;; Plain quoted symbols as keys (v1.8.0): colon-keywords like
  ;; :rafter-buckets are NOT reliably distinct symbols in every
  ;; AutoLISP reader (BricsCAD V26 mis-matched them in assoc, feeding
  ;; the buckets alist into arithmetic).  Ordinary symbols are safe on
  ;; every AutoCAD + BricsCAD version.
  (list (cons 'rafter-buckets   (cdr rafter-bucket-pair))
        (cons 'rafter-random-lf (car rafter-bucket-pair))
        (cons 'hrv-buckets      (cdr hrv-bucket-pair))
        (cons 'hrv-random-lf    (car hrv-bucket-pair))
        (cons 'area-by-pitch    area-by-pitch)
        (cons 'total-sf         total-sf)))

;; Make sure the chart layer exists and emit one TEXT entity.
(defun dsld-rpr-chart-text (pt str h / )
  (entmake (list (cons 0 "TEXT")
                 (cons 8 *DSLD-RPR-CHART-LAYER*)
                 (cons 10 pt)
                 (cons 40 h)
                 (cons 1  str)
                 (cons 7  *DSLD-RPR-TEXT-STYLE*)
                 (cons 50 0.0)
                 (cons 72 0)
                 (cons 73 0))))

;; Wipe existing chart text for this scan.  The chart is rendered
;; OUTSIDE the scan bbox -- starting at x = bbox-max-x + 2h -- so a
;; wipe inside the bbox never caught it and charts stacked on every
;; refresh (v1.8.0 fix).  The wipe zone extends from the bbox's right
;; edge out to ~50 text-heights and downward past the deepest chart,
;; and uses view-independent selection.
(defun dsld-rpr-wipe-chart (p1 p2 / h zone-p1 zone-p2)
  (setq h (* *DSLD-RPR-LABEL-HEIGHT* 1.4))
  (setq zone-p1 (list (max (car p1) (car p2))
                      (- (min (cadr p1) (cadr p2)) (* h 80.0))
                      0.0))
  (setq zone-p2 (list (+ (max (car p1) (car p2)) (* h 50.0))
                      (+ (max (cadr p1) (cadr p2)) (* h 4.0))
                      0.0))
  (foreach e (dsld-rpr-ents-in-bbox "TEXT" *DSLD-RPR-CHART-LAYER*
                                     zone-p1 zone-p2 0.0)
    (entdel e)))

;; Render the count chart at the upper-right of the bbox.  Three
;; sections: RAFTERS (bucketed + random LF) / H/R/V (same) / AREA BY
;; PITCH (per-pitch SF + grand total).
(defun dsld-rpr-render-chart (p1 p2 / counts h x y line-h
                               bbox-max-x bbox-max-y
                               r-buckets r-random h-buckets h-random
                               area-list total-sf lens len count
                               area-pitches p sf)
  (dsld-rpr-ensure-layer *DSLD-RPR-CHART-LAYER* (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-wipe-chart p1 p2)
  (setq counts     (dsld-rpr-collect-counts p1 p2))
  (setq r-buckets  (cdr (assoc 'rafter-buckets   counts)))
  (setq r-random   (cdr (assoc 'rafter-random-lf counts)))
  (setq h-buckets  (cdr (assoc 'hrv-buckets      counts)))
  (setq h-random   (cdr (assoc 'hrv-random-lf    counts)))
  (setq area-list  (cdr (assoc 'area-by-pitch    counts)))
  (setq total-sf   (cdr (assoc 'total-sf         counts)))
  (setq h      (* *DSLD-RPR-LABEL-HEIGHT* 1.4))
  (setq line-h (* h 1.6))
  (setq bbox-max-x (max (car  p1) (car  p2)))
  (setq bbox-max-y (max (cadr p1) (cadr p2)))
  (setq x (+ bbox-max-x (* h 2.0)))
  (setq y bbox-max-y)
  ;; -- header --
  (dsld-rpr-chart-text (list x y 0.0) "ROOF TAKEOFF" h)
  (setq y (- y line-h))
  (dsld-rpr-chart-text (list x y 0.0) "================" h)
  (setq y (- y line-h))
  ;; -- RAFTERS --
  (dsld-rpr-chart-text (list x y 0.0) "RAFTERS" h)
  (setq y (- y line-h))
  (setq lens (vl-sort (mapcar 'car r-buckets) '<))
  (foreach len lens
    (setq count (cdr (assoc len r-buckets)))
    (dsld-rpr-chart-text
      (list x y 0.0)
      (strcat "  " (itoa len) "'  x " (itoa count))
      h)
    (setq y (- y line-h)))
  (dsld-rpr-chart-text
    (list x y 0.0)
    (strcat "  random " (itoa (fix (+ r-random 0.5))) " LF")
    h)
  (setq y (- y line-h))
  (dsld-rpr-chart-text (list x y 0.0) "----------------" h)
  (setq y (- y line-h))
  ;; -- H/R/V --
  (dsld-rpr-chart-text (list x y 0.0) "H/R/V" h)
  (setq y (- y line-h))
  (setq lens (vl-sort (mapcar 'car h-buckets) '<))
  (foreach len lens
    (setq count (cdr (assoc len h-buckets)))
    (dsld-rpr-chart-text
      (list x y 0.0)
      (strcat "  " (itoa len) "'  x " (itoa count))
      h)
    (setq y (- y line-h)))
  (dsld-rpr-chart-text
    (list x y 0.0)
    (strcat "  random " (itoa (fix (+ h-random 0.5))) " LF")
    h)
  (setq y (- y line-h))
  (dsld-rpr-chart-text (list x y 0.0) "----------------" h)
  (setq y (- y line-h))
  ;; -- AREA BY PITCH --
  (dsld-rpr-chart-text (list x y 0.0) "AREA BY PITCH" h)
  (setq y (- y line-h))
  (setq area-pitches (vl-sort (mapcar 'car area-list) '<))
  (foreach p area-pitches
    (setq sf (cdr (assoc p area-list)))
    (dsld-rpr-chart-text
      (list x y 0.0)
      (strcat "  " (dsld-rpr-fmt-pitch p) "/12   "
              (itoa (fix (+ sf 0.5))) " SF")
      h)
    (setq y (- y line-h)))
  (dsld-rpr-chart-text
    (list x y 0.0)
    (strcat "  total   " (itoa (fix (+ total-sf 0.5))) " SF")
    h))

;;-----------------------------------------------------------------------;;
;; Main command
;;-----------------------------------------------------------------------;;

;; Single-pass workflow (v1.6.0):
;;   1. Bbox prompt
;;   2. Spacing prompt
;;   3. Trace every pitch callout in the window; render polygons + fills
;;      + pitch labels + rafters + length labels + H/R/V callouts +
;;      count chart immediately (no preview / edit gap).
;;   4. "Click missed area" loop -- for each click, BPOLY + prompt pitch
;;      + add the new region + refresh the bbox.  Enter ends the loop.
;;   5. Auto-install the live-edit watch reactor so subsequent grip-
;;      edits / moves / etc. trigger a silent refresh automatically.
;;   6. Hide design layers so the takeaway view is rafters + callouts +
;;      chart on top of base layers.  User can run RPRSHOW to inspect.

(defun c:RPR (/ oc oldlay oldecho p1 p2 picks pickpt pitch region count
              off-list win-area max-region-area traced pp
              new-traced applied kept e ss roof-layers lay overlapping
              poly new-poly missed-pt missed-pitch missed-region
              mo-pts mo-pt md-restored md-out-lays md-iso md-bb
              picks-info pick-i deco dd pik retry-picks blocker bpick
              shrunk kk perr hit orphan-picks rescued still-orphans
              rf capd ov-kept rescue-lays conflicts cf
              rp-pass rp-pending rp-next rp-kept-n diag-pairs
              grp grps gpick pieces pc-ok tot-a rr-reg
              hidden-dashed scan-id scan-tuple roof-lay-filter *error*)
  (vl-load-com)
  ;; Version banner: reports MUST tell us which build actually ran
  ;; (auto-update needs a restart to take effect and has lagged before).
  (princ (strcat "\n[RPR v" *DSLD-RPR-VERSION* "]"))
  ;; Local *error* binding: Esc / (exit) / hard errors all restore
  ;; sysvars, un-isolate layers, and rescue dashed linework from the
  ;; hidden temp layer.  Previous handler auto-restores on return.
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  ;; Rebuild the scan registry from persisted RPR<N> layers if this is
  ;; the first RPR of the session in an already-scanned drawing.
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))

  ;; --- ensure layers + text style ------------------------------------
  (dsld-rpr-ensure-layer *DSLD-RPR-RAFTER-LAYER*    (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-layer *DSLD-RPR-LABEL-LAYER*     *DSLD-RPR-PITCH-LAYER*)
  (dsld-rpr-ensure-layer *DSLD-RPR-FILL-LAYER*      (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-layer *DSLD-RPR-PITCH-LBL-LAYER* *DSLD-RPR-PITCH-LAYER*)
  (dsld-rpr-ensure-layer *DSLD-RPR-OVERLAP-LAYER*   (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-layer *DSLD-RPR-POLY-LAYER*      (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-layer *DSLD-RPR-CHART-LAYER*     (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-text-style *DSLD-RPR-TEXT-STYLE*
                              *DSLD-RPR-TEXT-FONT*
                              *DSLD-RPR-TEXT-WIDTH*)

  ;; --- preflight: reset cycle, free grip edits, show SSS layers ------
  (setq *DSLD-RPR-OUTLINE-CLR-IDX* 0)
  ;; AutoLISP has no lognot; -2 = ...11111110 clears bit 0 via logand.
  (setvar "PICKSTYLE" (logand (getvar "PICKSTYLE") -2))
  ;; Fills carry per-entity transparency; with TRANSPARENCYDISPLAY=0
  ;; (field ACA seats ship this way) they'd render opaque and bury the
  ;; roof linework.  Turn display on -- intentionally NOT restored:
  ;; correct rendering of RPR output requires it from now on.
  (vl-catch-all-apply
    '(lambda ()
       (if (zerop (getvar "TRANSPARENCYDISPLAY"))
         (setvar "TRANSPARENCYDISPLAY" 1))))
  ;; FILLMODE off renders SOLID hatches as outlines only -- force it on
  ;; so fills actually paint.
  (vl-catch-all-apply
    '(lambda ()
       (if (zerop (getvar "FILLMODE")) (setvar "FILLMODE" 1))))
  (dsld-rpr-set-layers-on
    (list *DSLD-RPR-POLY-LAYER*    *DSLD-RPR-FILL-LAYER*
          *DSLD-RPR-PITCH-LBL-LAYER* *DSLD-RPR-OVERLAP-LAYER*
          *DSLD-RPR-RAFTER-LAYER*    *DSLD-RPR-LABEL-LAYER*
          *DSLD-RPR-CHART-LAYER*)
    :vlax-true)

  ;; --- bbox + spacing prompts ----------------------------------------
  (setq p1 (getpoint "\n[RPR] Window the roof.  First corner: "))
  (if (not p1) (exit))
  (setq p2 (getcorner p1 "\nOpposite corner: "))
  (if (not p2) (exit))

  (setq oc (getreal (strcat "\nRafter spacing <"
                            (rtos *DSLD-RPR-LAST-OC* 2 2) ">: ")))
  (if (not oc) (setq oc *DSLD-RPR-LAST-OC*))
  (setq *DSLD-RPR-LAST-OC* oc)
  (setq *DSLD-RPR-LAST-BBOX* (list p1 p2))

  ;; --- scan slot allocation ------------------------------------------
  ;; If this bbox overlaps an existing scan's bbox, reuse that slot
  ;; (user is re-scanning the same roof).  Otherwise, allocate a new
  ;; slot with a fresh scan ID.  Polygons for THIS scan will live on
  ;; layer "RPR<N>" -- different scans keep their polygons on their
  ;; own layers so grip-editing / refreshing one scan doesn't touch
  ;; the others.
  (setq scan-tuple (dsld-rpr-find-overlapping-scan p1 p2))
  (cond
    (scan-tuple
     (setq scan-id (car scan-tuple))
     (princ (strcat "\n[RPR] Re-scanning slot " (itoa scan-id) ".")))
    (T
     (setq *DSLD-RPR-SCAN-COUNTER* (1+ *DSLD-RPR-SCAN-COUNTER*))
     (setq scan-id *DSLD-RPR-SCAN-COUNTER*)
     (princ (strcat "\n[RPR] Scan slot " (itoa scan-id) "."))))
  (setq *DSLD-RPR-POLY-LAYER* (dsld-rpr-scan-layer scan-id))
  (dsld-rpr-ensure-layer *DSLD-RPR-POLY-LAYER*
                          (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-register-scan scan-id p1 p2 oc)

  ;; --- find pitch callouts in window (or prompt manually) ------------
  (setq picks (dsld-rpr-find-pitch-text p1 p2))
  (cond
    (picks nil)            ; got them automatically; no message
    (T
     (while (setq pickpt (getpoint "\nClick inside pitch zone (Enter to finish): "))
       (initget 6)
       (setq pitch (getreal "\nPitch (e.g. 6 or 6.5): "))
       (if pitch (setq picks (cons (cons pickpt pitch) picks))))))
  (if (not picks) (exit))

  ;; --- discover roof-structure layers in window + isolate ------------
  (setq oldlay (getvar "CLAYER"))
  (dsld-rpr-stash 'clayer oldlay)
  (setvar "CLAYER" *DSLD-RPR-RAFTER-LAYER*)
  (setq win-area (* (abs (- (car p2) (car p1)))
                    (abs (- (cadr p2) (cadr p1)))))
  (setq max-region-area (* win-area 0.7))

  ;; STRICT mode (v1.9.10): trace against the configured roof layers
  ;; only -- no discovery, no stray-layer boundaries, deterministic.
  (cond
    (*DSLD-RPR-STRICT-LAYERS*
     (setq roof-layers *DSLD-RPR-ROOF-LAYERS*)
     (princ (strcat "\n[RPR] Strict layers: "
                    (apply 'strcat (dsld-rpr-comma-join roof-layers)))))
    (T
     (setq roof-layers '())
     (setq ss (ssget "_C" p1 p2
                '((0 . "LINE,LWPOLYLINE,POLYLINE,ARC,CIRCLE,SPLINE,ELLIPSE"))))
     (foreach e (dsld-rpr-ss->list ss)
       (setq lay (cdr (assoc 8 (entget e))))
       (if (and (not (dsld-rpr-is-noise-layer lay))
                (not (member lay roof-layers)))
         (setq roof-layers (cons lay roof-layers))))
     (if (not roof-layers) (setq roof-layers *DSLD-RPR-ROOF-LAYERS*))))
  ;; comma-joined layer filter for auto-close bridging (v1.9.0)
  (setq roof-lay-filter (apply 'strcat (dsld-rpr-comma-join roof-layers)))

  (setq off-list
        (dsld-rpr-isolate-layers
          (append roof-layers
                  (list *DSLD-RPR-RAFTER-LAYER*
                        *DSLD-RPR-LABEL-LAYER*
                        *DSLD-RPR-FILL-LAYER*
                        *DSLD-RPR-PITCH-LBL-LAYER*))))
  (dsld-rpr-stash 'off-list off-list)

  ;; --- wipe prior-run output INSIDE THE WINDOW ONLY ------------------
  ;; (so scanning a second roof doesn't delete the first roof's output.)
  (setq ss (ssget "_C" p1 p2 (list (cons 8
    (strcat *DSLD-RPR-RAFTER-LAYER* ","
            *DSLD-RPR-POLY-LAYER* ","
            *DSLD-RPR-LABEL-LAYER* ","
            *DSLD-RPR-FILL-LAYER* ","
            *DSLD-RPR-PITCH-LBL-LAYER* ","
            *DSLD-RPR-CHART-LAYER* ","
            *DSLD-RPR-OVERLAP-LAYER*)))))
  (if ss (foreach e (dsld-rpr-ss->list ss) (entdel e)))

  ;; --- hide non-solid linetype lines in window ------------------------
  ;; Dashed / hidden / center linetypes typically denote framing below
  ;; the roof surface (dormer supports, headers, etc.).  If BPOLY sees
  ;; them as boundaries it splits a roof region where the dashed line
  ;; crosses.  They're moved to a hidden temp layer during tracing;
  ;; the stash lets *error* rescue them if the user Escs mid-command.
  (setq hidden-dashed (dsld-rpr-hide-non-solid-in-bbox p1 p2))
  (dsld-rpr-stash 'hidden hidden-dashed)

  ;; --- trace each pitch pick into a polygon --------------------------
  ;; Silent loop -- one summary line at the end instead of per-region
  ;; chatter.  Each pick is remembered as (pickpt pitch region) so the
  ;; second-chance pass below can retry the ones that failed or lost.
  (setq picks-info '() count 0)
  (foreach pp picks
    (setq pickpt (car pp) pitch (cdr pp))
    ;; auto-close fallback bridges dangling endpoints when the region
    ;; is genuinely open-sided (porch / eave strips) -- v1.9.0
    (setq region (dsld-rpr-bpoly-auto-close pickpt roof-lay-filter))
    (if (and region
             (> (dsld-rpr-region-bbox-area region) max-region-area))
      (progn (entdel region) (setq region nil)))
    (dsld-rpr-dbg (strcat "pass1 pick " (itoa count) " pitch "
                          (rtos pitch 2 1) " -> "
                          (if region
                            (strcat "region area "
                                    (rtos (dsld-rpr-poly-area-flat region) 2 0))
                            "nil")))
    (setq picks-info (cons (list pickpt pitch region) picks-info))
    (setq count (1+ count)))
  (setq picks-info (reverse picks-info))

  ;; --- dedupe, SMALLEST-FIRST (v1.9.9) --------------------------------
  ;; A pick whose slope is bounded by dashed linework (hidden during
  ;; tracing) FLOODS into the neighboring slope, producing a bigger
  ;; region that duplicates it.  Sorting ascending by area before
  ;; deduping makes the TIGHT trace win over the flood regardless of
  ;; pick order.  Strict total order (area, then index) because vl-sort
  ;; may drop elements it considers equal.
  (setq deco '() pick-i 0)
  (foreach pik picks-info
    (if (caddr pik)
      (setq deco (cons (list (dsld-rpr-poly-area-flat (caddr pik))
                             pick-i pik)
                       deco)))
    (setq pick-i (1+ pick-i)))
  (setq deco (vl-sort deco
               '(lambda (a b)
                  (if (< (abs (- (car a) (car b))) 1e-6)
                    (< (cadr a) (cadr b))
                    (< (car a) (car b))))))
  (setq kept '() retry-picks '())
  (foreach dd deco
    (setq pik (caddr dd))
    (setq region (caddr pik))
    (cond
      ((dsld-rpr-region-duplicate-of region (mapcar 'caddr kept))
       (entdel region)
       ;; the pick lost its region -- queue for the dashed-visible retry
       (setq retry-picks (append retry-picks
                                 (list (list (car pik) (cadr pik) nil)))))
      (T (setq kept (append kept (list pik))))))
  ;; picks whose pass-1 trace failed outright also get a second chance
  (foreach pik picks-info
    (if (not (caddr pik))
      (setq retry-picks (append retry-picks (list pik)))))
  (dsld-rpr-dbg (strcat "dedupe done: kept " (itoa (length kept))
                        " retry " (itoa (length retry-picks))))

  ;; --- second chance: retry losers with dashed linework visible ------
  ;; (v1.9.9)  A slope bounded by dashed/hidden lines (e.g. an 8/12
  ;; band beside a 12/12 plane) can only trace tight when those lines
  ;; are visible -- the same rule the missed-area loop already uses.
  ;; If the retry is blocked by a kept FLOOD, the flood's own pick is
  ;; retraced too; a significantly tighter result replaces the flood.
  ;; v1.9.13: TWO passes -- A restores only the DIAGONAL dashes
  ;; (valley/hip boundaries; cardinal framing clutter stays hidden so
  ;; nothing fragments), B restores everything (dormers and cardinal
  ;; dividers).  A pick that captures in pass A skips pass B.
  (cond
    (retry-picks
     (setq rp-pass 1 rp-pending retry-picks)
     (while (and rp-pending (<= rp-pass 2))
       (if (= rp-pass 1)
         (dsld-rpr-restore-diagonals hidden-dashed)
         (dsld-rpr-restore-visible hidden-dashed))
       (dsld-rpr-dbg (strcat "second-chance pass " (itoa rp-pass)
                             ": " (itoa (length rp-pending)) " picks"))
       (setq rp-next '())
       (foreach pik rp-pending
       (setq rp-kept-n (length kept))
       (setq pickpt (car pik) pitch (cadr pik))
       (dsld-rpr-dbg (strcat "retry pick pitch " (rtos pitch 2 1)))
       (setq region (dsld-rpr-bpoly-auto-close pickpt roof-lay-filter))
       (dsld-rpr-dbg (strcat "  retry trace -> "
                             (if region
                               (rtos (dsld-rpr-poly-area-flat region) 2 0)
                               "nil")))
       (cond
         ((not region) nil)
         ((> (dsld-rpr-region-bbox-area region) max-region-area)
          (entdel region))
         (T
          (setq blocker (dsld-rpr-region-duplicate-of
                          region (mapcar 'caddr kept)))
          (cond
            ((not blocker)
             ;; even a non-duplicate retry must not overlap ANY kept
             ;; region: with every dashed line visible a retry can
             ;; trace a sliver cut out of a legitimate slope.  A real
             ;; missed band was a HOLE in coverage -- it overlaps
             ;; nothing.
             (setq hit nil)
             (foreach kk kept
               (if (and (not hit)
                        (dsld-rpr-regions-overlap-p region (caddr kk)))
                 (setq hit T)))
             (cond
               (hit
                (dsld-rpr-dbg "  retry rejected: overlaps kept")
                (entdel region))
               (T
                (dsld-rpr-snap-region-to-kept region (mapcar 'caddr kept)
                                              6.0)
                (setq kept (append kept
                                   (list (list pickpt pitch region)))))))
            (T
             ;; the blocker may itself be a flood (two slopes divided
             ;; only by dashed lines, traced as one): retrace ITS pick
             ;; with dashes visible.  Swap ONLY under CONSERVATION --
             ;; the shrunk piece plus the retry piece must together
             ;; cover what the blocker covered, and be disjoint.  A
             ;; dashed-cut sliver fails this, so a legitimate region is
             ;; never traded for fragments.
             (setq bpick nil)
             (foreach kk kept
               (if (eq (caddr kk) blocker) (setq bpick kk)))
             (setq shrunk (if bpick
                            (dsld-rpr-bpoly-auto-close (car bpick)
                                                       roof-lay-filter)))
             (cond
               ((and shrunk
                     (< (dsld-rpr-poly-area-flat shrunk)
                        (* 0.85 (dsld-rpr-poly-area-flat blocker)))
                     (>= (+ (dsld-rpr-poly-area-flat shrunk)
                            (dsld-rpr-poly-area-flat region))
                         (* 0.85 (dsld-rpr-poly-area-flat blocker)))
                     (not (dsld-rpr-regions-overlap-p shrunk region)))
                (dsld-rpr-dbg "  flood split: blocker swapped for pieces")
                (entdel blocker)
                (setq kept (subst (list (car bpick) (cadr bpick) shrunk)
                                  bpick kept))
                (dsld-rpr-snap-region-to-kept shrunk
                                              (mapcar 'caddr kept) 6.0)
                (dsld-rpr-snap-region-to-kept region
                                              (mapcar 'caddr kept) 6.0)
                (setq kept (append kept
                                   (list (list pickpt pitch region)))))
               (T
                (dsld-rpr-dbg "  retry rejected: no conservation")
                (if shrunk (entdel shrunk))
                (entdel region)))))))
       ;; pick captured nothing this pass -> try again next pass
       (if (= (length kept) rp-kept-n)
         (setq rp-next (cons pik rp-next))))
       (setq rp-pending (reverse rp-next))
       (setq rp-pass (1+ rp-pass)))
     ;; back to main-scan visibility rules
     (setq hidden-dashed (dsld-rpr-hide-non-solid-in-bbox p1 p2))
     (dsld-rpr-stash 'hidden hidden-dashed)))
  (dsld-rpr-dbg (strcat "second-chance done: kept " (itoa (length kept))))

  ;; --- finalize the kept set: layer, pitch tag, outline tint ----------
  (setq traced '())
  (foreach pik kept
    (setq region (caddr pik) pitch (cadr pik))
    (entmod (subst (cons 8 *DSLD-RPR-POLY-LAYER*)
                   (assoc 8 (entget region))
                   (entget region)))
    (dsld-rpr-tag-pitch region pitch)
    (dsld-rpr-tint-poly region)
    (setq traced (cons (list region pitch) traced)))
  (setq traced (reverse traced))
  (dsld-rpr-dbg (strcat "finalize done: traced " (itoa (length traced))))

  ;; --- region-boolean orphan rescue (v1.9.11) -------------------------
  ;; Runs HERE -- isolation still on, dashes hidden, no derived output
  ;; drawn yet -- so rescue floods see exactly what pass-1 saw.  An
  ;; orphan's dashes-hidden trace overlaps kept neighbors (that is WHY
  ;; dedupe killed it); flood MINUS those neighbors IS the missing
  ;; slope.  ActiveX region booleans do the subtraction (headless
  ;; sessions without a document object just skip; the callout stays
  ;; reported below).  Rescued regions join `traced` and flow through
  ;; the normal render pipeline.
  (setq orphan-picks '())
  (foreach pp picks
    (setq hit nil)
    (foreach pik kept
      (if (and (not hit)
               (dsld-rpr-pt-in-poly (car pp) (caddr pik)))
        (setq hit T)))
    (if (not hit) (setq orphan-picks (cons pp orphan-picks))))
  (setq orphan-picks (reverse orphan-picks))
  (setq rescued 0 still-orphans '())
  ;; multi-pitch groups (v1.9.13): kept regions containing callouts of
  ;; a DIFFERENT pitch -- surviving multi-slope floods to split below.
  (setq grps '())
  (foreach pp picks
    (foreach pik kept
      (if (and (dsld-rpr-pt-in-poly (car pp) (caddr pik))
               (> (abs (- (cdr pp) (cadr pik))) 0.01))
        (progn
          (setq grp (assoc (caddr pik) grps))
          (if grp
            (setq grps (subst (cons (car grp) (cons pp (cdr grp)))
                              grp grps))
            (setq grps (cons (list (caddr pik) pp) grps)))))))
  ;; hide every scan-poly layer for the rescue traces: kept region
  ;; polylines deflect BPOLY; the subtraction is what accounts for them
  (setq rescue-lays (list *DSLD-RPR-POLY-LAYER*))
  (foreach s *DSLD-RPR-SCANS*
    (if (not (member (nth 4 s) rescue-lays))
      (setq rescue-lays (cons (nth 4 s) rescue-lays))))
  (if (or orphan-picks grps)
    (progn
      (dsld-rpr-set-layers-on rescue-lays :vlax-false)
      ;; v1.9.13: valley/hip boundaries visible during rescue traces --
      ;; floods bounded by diagonal dashes now trace TIGHT directly
      ;; (no overlap -> captured without any subtraction)
      (setq diag-pairs (dsld-rpr-restore-diagonals hidden-dashed))))
  (foreach pp orphan-picks
    (dsld-rpr-dbg (strcat "rescue attempt pitch " (rtos (cdr pp) 2 1)
                          " at (" (rtos (car (car pp)) 2 0) ","
                          (rtos (cadr (car pp)) 2 0) ")"))
    (setq rf (dsld-rpr-bpoly-auto-close (car pp) roof-lay-filter))
    (if (and rf (> (dsld-rpr-region-bbox-area rf) max-region-area))
      (progn (entdel rf) (setq rf nil)))
    (dsld-rpr-dbg (strcat "  rescue flood -> "
                          (if rf (rtos (dsld-rpr-poly-area-flat rf) 2 0)
                                 "nil")))
    (setq capd nil)
    (cond
      (rf
       (setq ov-kept '())
       (foreach pik kept
         (if (dsld-rpr-regions-overlap-p rf (caddr pik))
           (setq ov-kept (cons (caddr pik) ov-kept))))
       (cond
         ((not ov-kept)
          ;; overlaps nothing: the trace itself is the missing region
          (setq capd rf) (setq rf nil))
         ;; flood ~entirely inside ONE kept region: the slope is already
         ;; traced -- under a DIFFERENT pitch.  A double-pitched zone in
         ;; the drawing, not missing geometry: report as a pitch
         ;; CONFLICT for the user to verify (never auto-flip a pitch).
         ((and (not (cdr ov-kept))
               (>= (dsld-rpr-overlap-frac rf (car ov-kept)) 0.97))
          (setq conflicts
                (cons (list (car pp) (cdr pp)
                            (dsld-rpr-read-pitch (car ov-kept)))
                      conflicts))
          (dsld-rpr-dbg "  rescue: pitch conflict (slope already traced)")
          (entdel rf) (setq rf nil)
          (setq capd 'CONFLICT))
         (T
          (dsld-rpr-dbg (strcat "  rescue overlaps " (itoa (length ov-kept))
                                " kept -> subtracting"))
          (setq capd (dsld-rpr-region-subtract-capture
                       rf ov-kept (car pp) *DSLD-RPR-POLY-LAYER*))
          (dsld-rpr-dbg (strcat "  rescue capture -> "
                                (if capd
                                  (rtos (dsld-rpr-poly-area-flat capd) 2 0)
                                  "nil")))
          (entdel rf) (setq rf nil)
          (if (and capd
                   (or (< (dsld-rpr-poly-area-flat capd) 500.0)
                       (> (dsld-rpr-region-bbox-area capd)
                          max-region-area)))
            (progn (entdel capd) (setq capd nil)))))))
    (cond
      ((eq capd 'CONFLICT) nil)             ; reported separately below
      (capd
       (dsld-rpr-snap-region-to-kept capd (mapcar 'caddr kept) 6.0)
       (entmod (subst (cons 8 *DSLD-RPR-POLY-LAYER*)
                      (assoc 8 (entget capd))
                      (entget capd)))
       (dsld-rpr-tag-pitch capd (cdr pp))
       (dsld-rpr-tint-poly capd)
       (setq kept (append kept (list (list (car pp) (cdr pp) capd))))
       (setq traced (append traced (list (list capd (cdr pp)))))
       (setq rescued (1+ rescued))
       (dsld-rpr-dbg (strcat "rescued orphan pitch "
                             (rtos (cdr pp) 2 1) " area "
                             (rtos (dsld-rpr-poly-area-flat capd) 2 0))))
      (T (setq still-orphans (cons pp still-orphans)))))

  ;; --- flood split (v1.9.13): kept region holding FOREIGN callouts ----
  ;; A kept region containing pitch callouts whose pitch differs from
  ;; its own is a multi-slope FLOOD that survived (slopes divided by
  ;; dashed valleys traced as one -- rafters then run straight through
  ;; hips/valleys/returns).  With the diagonal dashes still visible,
  ;; retrace EVERY callout inside it; if the pieces are disjoint and
  ;; together cover the flood (conservation), swap the flood for the
  ;; pieces, each with its own callout's pitch.
  (foreach grp grps
    (setq rr-reg (car grp))
    (cond
      ((not (entget rr-reg)) nil)          ; already replaced/deleted
      (T
       ;; the flood's OWN pick (kept entry) + the foreign callouts;
       ;; every entry normalized to (pt . pitch)
       (setq bpick nil)
       (foreach pik kept
         (if (eq (caddr pik) rr-reg) (setq bpick pik)))
       (setq gpick (cons (cons (car bpick) (cadr bpick)) (cdr grp)))
       (dsld-rpr-dbg (strcat "flood-split attempt: "
                             (itoa (length gpick)) " picks in region "
                             (rtos (dsld-rpr-poly-area-flat rr-reg) 2 0)))
       (setq pieces '() pc-ok T)
       (foreach pp gpick
         (setq rf (dsld-rpr-bpoly-auto-close (car pp) roof-lay-filter))
         (cond
           ((not rf) (setq pc-ok nil))
           ((> (dsld-rpr-region-bbox-area rf)
               (dsld-rpr-region-bbox-area rr-reg))
            (entdel rf) (setq pc-ok nil))
           (T (setq pieces (cons (cons rf (cdr pp)) pieces)))))
       ;; validation: pairwise disjoint + conservation vs the flood
       (cond
         (pc-ok
          (setq tot-a 0.0)
          (foreach pc pieces
            (setq tot-a (+ tot-a (dsld-rpr-poly-area-flat (car pc)))))
          (if (< tot-a (* 0.85 (dsld-rpr-poly-area-flat rr-reg)))
            (setq pc-ok nil))
          (foreach pc pieces
            (foreach pc2 pieces
              (if (and pc-ok (not (eq pc pc2))
                       (dsld-rpr-regions-overlap-p (car pc) (car pc2)))
                (setq pc-ok nil))))))
       (cond
         ((and pc-ok (> (length pieces) 1))
          (dsld-rpr-dbg "flood-split: SWAPPED for pieces")
          ;; remove the flood from kept/traced, delete it
          (setq kept (vl-remove bpick kept))
          (setq traced (vl-remove-if
                         '(lambda (tp) (eq (car tp) rr-reg)) traced))
          (entdel rr-reg)
          (foreach pc pieces
            (dsld-rpr-snap-region-to-kept (car pc)
                                          (mapcar 'caddr kept) 6.0)
            (entmod (subst (cons 8 *DSLD-RPR-POLY-LAYER*)
                           (assoc 8 (entget (car pc)))
                           (entget (car pc))))
            (dsld-rpr-tag-pitch (car pc) (cdr pc))
            (dsld-rpr-tint-poly (car pc))
            (setq kept (append kept (list (list nil (cdr pc) (car pc)))))
            (setq traced (append traced (list (list (car pc) (cdr pc))))))
          (setq rescued (1+ rescued)))
         (T
          (dsld-rpr-dbg "flood-split: rejected (conservation/overlap)")
          (foreach pc pieces (entdel (car pc))))))))

  (if orphan-picks
    (dsld-rpr-set-layers-on rescue-lays :vlax-true))
  (if diag-pairs (dsld-rpr-rehide-pairs diag-pairs))
  (if (> rescued 0)
    (princ (strcat "\n[RPR] Auto-captured " (itoa rescued)
                   " slope(s) by subtracting traced neighbors.")))
  (cond
    (conflicts
     (princ (strcat "\n[RPR] " (itoa (length conflicts))
                    " callout(s) sit on slopes ALREADY traced with a"
                    " different pitch -- verify these:"))
     (foreach cf (reverse conflicts)
       (princ (strcat "\n      callout "
                      (dsld-rpr-fmt-pitch (cadr cf)) "/12 at ("
                      (rtos (car (car cf)) 2 0) ", "
                      (rtos (cadr (car cf)) 2 0)
                      ") -- slope traced as "
                      (if (caddr cf)
                        (strcat (dsld-rpr-fmt-pitch (caddr cf)) "/12")
                        "?")
                      ".  RPRFIX changes it.")))))
  (setq orphan-picks (reverse still-orphans))

  ;; --- render everything for each polygon ----------------------------
  ;; process-single does fill + pitch label + rafters + length labels
  ;; internally.  (v1.8.0 fix: the explicit fill-region / label-pitch
  ;; calls that used to precede it stacked a SECOND hatch + label on
  ;; every region.)  Silent -- no per-region princ so the text window
  ;; doesn't auto-pop.
  ;; Each region individually caught (v1.9.9) -- mirrors the refresh
  ;; hardening: one bad region must not abort the whole scan (a LISP
  ;; error mid-command also cancels any running script).  The error is
  ;; recorded for RPRDIAG.
  (foreach pp traced
    (setq perr (vl-catch-all-apply
                 '(lambda () (dsld-rpr-process-single (car pp) (cadr pp) oc))))
    (cond
      ((vl-catch-all-error-p perr)
       (setq *DSLD-RPR-LAST-REFRESH-ERR*
             (strcat "scan process-single: "
                     (vl-catch-all-error-message perr)))
       (dsld-rpr-dbg (strcat "  PS ERROR: "
                             (vl-catch-all-error-message perr))))
      (T (dsld-rpr-dbg "  process-single ok"))))
  (dsld-rpr-dbg "render loop done")
  (dsld-rpr-label-all-shared-edges (mapcar 'car traced))
  (dsld-rpr-dbg "shared edges done")
  ;; junction rafters at every H/R/V intersection node (v1.9.14)
  (setq perr (vl-catch-all-apply
               '(lambda ()
                  (dsld-rpr-add-junction-rafters (mapcar 'car traced)))))
  (if (vl-catch-all-error-p perr)
    (setq *DSLD-RPR-LAST-REFRESH-ERR*
          (strcat "junction rafters: "
                  (vl-catch-all-error-message perr))))

  ;; --- overlap warnings (yellow markers on OVERLAP-LAYER) ------------
  (setq overlapping nil)
  (setq e (vl-catch-all-apply
            '(lambda ()
               (setq overlapping
                     (dsld-rpr-find-overlapping-polys
                       (mapcar 'car traced))))))
  (cond
    ((vl-catch-all-error-p e) nil)
    (overlapping
     (foreach poly overlapping
       (setq new-poly (dsld-rpr-make-lwpoly
                        (dsld-rpr-poly-vertices poly)
                        *DSLD-RPR-OVERLAP-LAYER*))
       (cond
         (new-poly
          (dsld-rpr-set-color      new-poly *DSLD-RPR-OVERLAP-COLOR*)
          (dsld-rpr-set-lineweight new-poly *DSLD-RPR-OVERLAP-LWT*))))))

  ;; --- lift layer isolation + render chart ---------------------------
  (dsld-rpr-restore-layers off-list)
  (dsld-rpr-render-chart p1 p2)
  (dsld-rpr-dbg "chart done; entering missed-area loop")

  ;; --- arm live-edit NOW, before the interactive loop (v1.9.15) ------
  ;; The missed-area loop below prompts.  Esc at that prompt throws to
  ;; *error*, which cleans up and RETURNS -- so everything after the
  ;; loop, including the weld snapshot and the reactor install, used to
  ;; be skipped entirely.  The user got a fully rendered takeoff with
  ;; live edit silently OFF and no snapshot: pulling a vertex then moved
  ;; nothing, updated nothing, and left the neighbour detached.  Arm it
  ;; here so Esc is as safe as Enter; the tail re-arms harmlessly.
  (vl-catch-all-apply 'dsld-rpr-vtx-snapshot)
  (vl-catch-all-apply 'dsld-rpr-ensure-watch)

  ;; --- missed-area loop: click any region BPOLY didn't catch ---------
  ;; Pass 1: normal trace (dashed still hidden, same rules as the main
  ;; scan).  A pass-1 result is REJECTED when it flooded out to a
  ;; region we already traced or past the size cap -- the dormer
  ;; under-roof case does exactly that, because the dormer's DASHED
  ;; boundary is on the hidden temp layer, so BPOLY "succeeds" with a
  ;; duplicate of the enclosing plane and (v1.9.1) the fallback never
  ;; fired.  Pass 2 (v1.9.2): restore the hidden dashed linework and
  ;; re-trace -- sub-roof boundaries are legitimate edges for a MISSED
  ;; area even though they must stay hidden for the main scan.  If ALL
  ;; of that fails, fall into corner-click outlining -- the user must
  ;; NEVER be left without a way to capture the area they clicked.
  ;; RPR's own output (rafter LINEs, H/R/V circles, fills) is legit
  ;; BPOLY boundary geometry -- a click INSIDE an already-rafted region
  ;; (dormer under-roof strip) would trace a sliver between two rafters.
  ;; Blind every trace to our output by toggling those layers off for
  ;; just the trace calls.  Scan-poly layers stay visible: they are
  ;; real region boundaries.
  (setq md-out-lays (list *DSLD-RPR-RAFTER-LAYER* *DSLD-RPR-LABEL-LAYER*
                          *DSLD-RPR-FILL-LAYER*   *DSLD-RPR-PITCH-LBL-LAYER*
                          *DSLD-RPR-CHART-LAYER*  *DSLD-RPR-OVERLAP-LAYER*))
  ;; Report the pitch callouts that STILL have no region after the
  ;; rescue pass -- they are precisely the spots to click / outline in
  ;; the missed-area loop below.
  (cond
    (orphan-picks
     (princ (strcat "\n[RPR] " (itoa (length orphan-picks))
                    " pitch callout(s) got NO region -- capture them now:"))
     (foreach pp orphan-picks
       (princ (strcat "\n      " (dsld-rpr-fmt-pitch (cdr pp))
                      "/12 near ("
                      (rtos (car (car pp)) 2 0) ", "
                      (rtos (cadr (car pp)) 2 0) ")")))))
  (while (setq missed-pt
            (getpoint "\n[RPR] Click missed area (Enter=done): "))
    (setq md-restored nil)
    (dsld-rpr-set-layers-on md-out-lays :vlax-false)
    ;; v1.9.15: Esc between here and the restore below used to leave the
    ;; rafter / callout / fill layers switched OFF -- the user saw their
    ;; whole takeoff "disappear".  Register the restore with the error
    ;; handler for the duration of the trace.
    (dsld-rpr-stash 'md-off md-out-lays)
    ;; v1.9.15: layer isolation was LIFTED before this loop (line ~3969),
    ;; so BPOLY was free to close the click against walls, dimensions,
    ;; hatch boundaries -- anything still visible.  That is why a click
    ;; in a genuinely missed roof area came back with a wrong shape (then
    ;; rejected as "bad") or nothing at all.  Re-isolate to the roof
    ;; layers for the trace only, exactly as the main scan does.
    (setq md-iso (dsld-rpr-isolate-layers
                   (append roof-layers (list *DSLD-RPR-POLY-LAYER*))))
    (dsld-rpr-stash 'md-iso md-iso)
    ;; pass 1: same visibility rules as the main scan (dashed hidden)
    (setq missed-region
          (dsld-rpr-bpoly-auto-close missed-pt roof-lay-filter))
    (if (and missed-region
             (dsld-rpr-missed-region-bad-p missed-region max-region-area))
      (progn (entdel missed-region) (setq missed-region nil)))
    (cond
      ((not missed-region)
       ;; pass 2a (v1.9.13): diagonal dashes only -- valley-bounded
       ;; zones trace tight without fragmenting on cardinal framing
       (dsld-rpr-restore-diagonals hidden-dashed)
       (setq md-restored T)
       (setq missed-region
             (dsld-rpr-bpoly-auto-close missed-pt roof-lay-filter))
       (if (and missed-region
                (dsld-rpr-missed-region-bad-p missed-region
                                              max-region-area))
         (progn (entdel missed-region) (setq missed-region nil)))))
    (cond
      ((not missed-region)
       ;; pass 2b: restore ALL the hidden dashed linework and re-trace
       ;; -- sub-roof boundaries (dormer supports) are legitimate edges
       ;; for a MISSED area even though the main scan must hide them.
       (dsld-rpr-restore-visible hidden-dashed)
       (setq md-restored T)
       (setq missed-region
             (dsld-rpr-bpoly-auto-close missed-pt roof-lay-filter))
       (if (and missed-region
                (dsld-rpr-missed-region-bad-p missed-region
                                              max-region-area))
         (progn (entdel missed-region) (setq missed-region nil)))))
    ;; lift the trace-only isolation BEFORE any further prompting, so the
    ;; user can see the plan they are about to outline by hand
    (dsld-rpr-restore-layers md-iso)
    (setq md-iso nil)
    (dsld-rpr-set-layers-on md-out-lays :vlax-true)
    (cond
      ((not missed-region)
       ;; guaranteed fallback: outline it by corner clicks, inline.
       ;; (Dashed linework is still visible here when pass 2 ran, so
       ;; the user can see the dormer boundary they're outlining.)
       (princ "\n[RPR] Couldn't auto-trace there.  Outline it instead:")
       (setq mo-pts '())
       (while (setq mo-pt
                 (getpoint (if mo-pts (last mo-pts))
                           (if mo-pts "\nNext corner [Enter=close]: "
                                      "\nFirst corner of area: ")))
         (setq mo-pts (append mo-pts (list mo-pt))))
       (if (>= (length mo-pts) 3)
         (setq missed-region
               (dsld-rpr-make-lwpoly mo-pts *DSLD-RPR-POLY-LAYER*))
         (princ "\n[RPR] (need 3+ corners -- skipped)"))))
    ;; re-hide the dashed linework pass 2 restored, so the next loop
    ;; iteration (and the rest of the command) sees main-scan rules
    ;; v1.9.15: APPEND, don't replace.  hide-non-solid-in-bbox refuses to
    ;; re-record anything already sitting on the hidden temp layer, so
    ;; after a pass-2a run (which restores only the DIAGONAL dashes) the
    ;; still-hidden cardinal dashes vanished from hidden-dashed -- and
    ;; the end-of-command restore then left them stranded on an OFF
    ;; layer, silently deleting the user's dashed framing from the plan.
    (cond
      (md-restored
       (setq hidden-dashed
             (append (dsld-rpr-hide-non-solid-in-bbox p1 p2)
                     (vl-remove-if '(lambda (pr) (not (entget (car pr))))
                                   hidden-dashed)))
       (dsld-rpr-stash 'hidden hidden-dashed)))
    (cond
      (missed-region
       (initget 6)
       (setq missed-pitch (getreal "\nPitch (e.g. 6 or 6.5): "))
       (cond
         ((not missed-pitch)
          (entdel missed-region))        ; user bailed -- drop the trace
         (T
          (entmod (subst (cons 8 *DSLD-RPR-POLY-LAYER*)
                         (assoc 8 (entget missed-region))
                         (entget missed-region)))
          (dsld-rpr-tag-pitch missed-region missed-pitch)
          (dsld-rpr-tint-poly missed-region)
          ;; v1.9.15: grow the scan slot to cover the captured area.  A
          ;; missed region reached past the original window was rendered
          ;; once here and then dropped out of every later refresh --
          ;; "I added the area and it never updated again".
          (setq md-bb (dsld-rpr-poly-bbox missed-region))
          (setq scan-tuple
                (dsld-rpr-register-scan
                  scan-id
                  (list (- (car  (car md-bb)) (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
                        (- (cadr (car md-bb)) (* *DSLD-RPR-LABEL-HEIGHT* 6.0)) 0.0)
                  (list (+ (car  (cadr md-bb)) (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
                        (+ (cadr (cadr md-bb)) (* *DSLD-RPR-LABEL-HEIGHT* 6.0)) 0.0)
                  oc))
          ;; Re-render the whole window so rafters + H/R/V + chart
          ;; account for the new region.
          ;; v1.9.15: CAUGHT.  refresh-silent sets *DSLD-RPR-REFRESHING*
          ;; on entry and clears it only on the way out, so a throw here
          ;; used to strand the flag at T -- which permanently gags the
          ;; live-edit reactor (it tests that flag first) for the rest of
          ;; the session.  Every later grip edit then did nothing at all.
          (setq perr (vl-catch-all-apply
                       '(lambda () (dsld-rpr-refresh-silent p1 p2))))
          (setq *DSLD-RPR-REFRESHING* nil)
          (if (vl-catch-all-error-p perr)
            (progn
              (setq *DSLD-RPR-LAST-REFRESH-ERR*
                    (strcat "missed-area refresh: "
                            (vl-catch-all-error-message perr)))
              (princ (strcat "\n[RPR] Added the area, but the re-render hit: "
                             (vl-catch-all-error-message perr)))))))))
    (setq missed-region nil))

  ;; --- restore visibility of any dashed lines we hid for tracing -----
  (dsld-rpr-restore-visible hidden-dashed)

  ;; --- drop the slot again if nothing was actually traced ------------
  ;; (Esc'd early / all BPOLYs failed.)  Otherwise the reactor would
  ;; refresh an empty window forever and render a zero-count chart.
  (if (not (dsld-rpr-ents-in-bbox "LWPOLYLINE" *DSLD-RPR-POLY-LAYER*
                                   p1 p2 0.0))
    (dsld-rpr-forget-scan scan-id))

  ;; --- auto-hide design-only layers ----------------------------------
  ;; Hide the color fills + overlap warnings so the finished view
  ;; shows only rafters + labels + H/R/V + SF callouts + chart.
  ;; POLY-LAYER stays VISIBLE (v1.7.7+) so the user can immediately
  ;; grip-edit polygons -- in AutoCAD you can't select what's hidden.
  ;; Run RPRRESULT to hide POLY-LAYER as well for a fully clean output.
  (dsld-rpr-set-layers-on
    (list *DSLD-RPR-FILL-LAYER*
          *DSLD-RPR-OVERLAP-LAYER*)
    :vlax-false)

  ;; weld snapshot for live-edit (v1.9.12)
  (vl-catch-all-apply 'dsld-rpr-vtx-snapshot)

  ;; --- auto-install watch reactor (live edit mode) -------------------
  (dsld-rpr-ensure-watch)

  ;; Normal-path cleanup (same routine *error* uses, so Esc and success
  ;; leave identical state).
  (dsld-rpr-cleanup)
  ;; Force focus back to the graphics screen in case BricsCAD popped
  ;; up the text-history window during the command's output.
  (vl-catch-all-apply 'graphscr)
  (princ))


;;-----------------------------------------------------------------------;;
;; Manual override:  RPRFIX
;;-----------------------------------------------------------------------;;
;; Pick a region polygon (the LWPOLYLINE on A-Roof-OtlnSSS that the auto-run
;; created), supply your own rafter direction (H/V) and origin point,
;; and the routine wipes the existing rafters/labels in that polygon and
;; regenerates them with the new params.  Pitch is auto-detected from
;; the fill-hatch color (or prompted if it can't be detected).
;; Lengths are recalculated and rounded per the DSLD rule.
;;
(defun c:RPRFIX (/ oldecho oldlay click-pt region pitch curr-pitch
                   bb w h auto-dir dir-input new-dir
                   pitch-input new-pitch origin-pt killed rafters
                   *error*)
  (vl-load-com)
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (dsld-rpr-stash 'clayer  (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  (setvar "CLAYER" *DSLD-RPR-RAFTER-LAYER*)

  ;; Use a click-inside-the-region point instead of entsel.  This avoids
  ;; the bug where clicking near a shared boundary picks the wrong
  ;; polygon, and where bbox-center-based hatch lookup can land outside
  ;; concave polygons.
  (princ "\n[RPRFIX] Click inside the region to fix.")
  (setq click-pt (getpoint "\nClick inside region: "))
  (cond
    ((not click-pt)
     (princ "\n[RPRFIX] Cancelled."))
    (T
     (setq region (dsld-rpr-find-polygon-at click-pt))
     (cond
       ((not region)
        (princ "\n[RPRFIX] No region polygon under that point."))
       (T
        (setq curr-pitch (dsld-rpr-pitch-of-region region))
        (cond
          (curr-pitch
           (princ (strcat "\n[RPRFIX] Current pitch: "
                          (dsld-rpr-fmt-pitch curr-pitch) "/12.")))
          (T
           (initget 6)
           (setq curr-pitch
             (getreal "\n[RPRFIX] Pitch rise (e.g. 6 or 6.5 for 6/12 or 6.5/12): "))))
        (cond
          ((not curr-pitch)
           ;; v1.8.0: Enter at the pitch prompt used to crash on
           ;; (float nil) further down; now it just cancels.
           (princ "\n[RPRFIX] No pitch supplied.  Cancelled."))
          (T
           (setq bb (dsld-rpr-poly-bbox region))
           (setq w (abs (- (car  (cadr bb)) (car  (car bb)))))
           (setq h (abs (- (cadr (cadr bb)) (cadr (car bb)))))
           (setq auto-dir (if (>= w h) "V" "H"))

           ;; --- Three optional prompts.  Enter on each = keep current.

           (setq pitch-input
                 (getreal (strcat "\nNew pitch rise [Enter to keep "
                                  (dsld-rpr-fmt-pitch curr-pitch) "]: ")))
           (setq new-pitch (if pitch-input pitch-input curr-pitch))

           (initget "H V Auto")
           (setq dir-input
                 (getkword (strcat "\nDirection [H/V/Auto] <" auto-dir ">: ")))
           (if (or (not dir-input) (= dir-input "Auto"))
             (setq dir-input auto-dir))
           (setq new-dir (if (= dir-input "H") 0.0 (/ pi 2.0)))

           (setq origin-pt
                 (getpoint "\nOrigin point [Enter to use bbox center]: "))
           (if (not origin-pt) (setq origin-pt (dsld-rpr-bbox-center bb)))

           ;; --- Apply changes ---
           (setq killed (dsld-rpr-clear-region region))
           ;; v1.8.0: persist pitch (XDATA) so refreshes stop reverting
           ;; the correction -- the chart reads XDATA, and the reactor
           ;; regenerates from XDATA.  Also persist direction/origin.
           (dsld-rpr-tag-pitch region new-pitch)
           (dsld-rpr-tag-override region
                                  (if (= dir-input "H") 0 1)
                                  origin-pt)
           (if (/= new-pitch curr-pitch)
             (dsld-rpr-recolor-fill-hatch region new-pitch))
           (setq rafters (dsld-rpr-build-rafters-at
                           region origin-pt new-dir *DSLD-RPR-LAST-OC*))
           (foreach rl rafters (dsld-rpr-label-rafter rl new-pitch))
           (dsld-rpr-label-pitch region new-pitch)
           (princ (strcat "\n[RPRFIX] " (dsld-rpr-fmt-pitch new-pitch)
                          "/12, "
                          (if (= dir-input "H") "horizontal" "vertical")
                          ", " (itoa (length rafters)) " rafters."))))))))

  (dsld-rpr-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; Manual split:  RPRSPLIT
;;-----------------------------------------------------------------------;;
;; Pick a polygon (or its fill hatch), then two points defining a cut
;; line, and the polygon is replaced by two sub-polygons split at that
;; line.  Each sub-polygon inherits the original pitch and fill color.
;; Old rafters/labels in the original polygon are wiped; pitch labels
;; are placed in each new sub-polygon.  Use RPRFIX on each sub-polygon
;; afterwards to set its direction and origin.
;;
;; Find the roof polygon (LWPOLYLINE on ANY scan layer) that contains
;; the given point, or nil if none.  v1.8.0: searches "RPR*" plus the
;; legacy pre-1.7.7 outline layer instead of only the most recent
;; scan's layer -- RPRFIX / RPRADD on an older roof used to come back
;; "no region polygon under that point".  A polygon on a matched layer
;; must also carry DSLD_RPR pitch xdata (or be on the legacy layer) so
;; a user layer that happens to start with "RPR" can't false-match.
(defun dsld-rpr-find-polygon-at (pt / ss n i poly lay result)
  (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE")
                             (cons 8 (strcat "RPR*,A-Roof-OtlnSSS")))))
  (if ss
    (progn
      (setq n (sslength ss) i 0)
      (while (and (< i n) (not result))
        (setq poly (ssname ss i))
        (setq lay  (cdr (assoc 8 (entget poly))))
        (if (and (or (dsld-rpr-scan-id-from-layer lay)
                     (= (strcase lay) (strcase "A-Roof-OtlnSSS")))
                 (dsld-rpr-pt-in-poly pt poly))
          (setq result poly))
        (setq i (1+ i)))))
  result)

;; (RPRSPLIT removed in v1.6.0 -- user can draw a LINE inside a region
;;  before running RPR and BPOLY will trace around it, or grip-edit a
;;  polygon to add a dividing vertex, then RPRREFRESH regenerates.)

;;-----------------------------------------------------------------------;;
;; Manual add:  RPRADD
;;-----------------------------------------------------------------------;;
;; Draw a single rafter line and have it labeled with the correct
;; on-pitch length.  Pitch is auto-detected from the polygon under the
;; line's midpoint (falls back to a prompt).
;; Hip / ridge / valley callouts are generated automatically by RPR
;; (Phase 3).  This command is rafter-only.
;;
(defun c:RPRADD (/ oldecho oldlay p1 p2 mid region pitch
                   len-flat factor len-true len-true-ft rounded line
                   lbl-before lbl-after *error*)
  (vl-load-com)
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (dsld-rpr-stash 'clayer  (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  (setvar "CLAYER" *DSLD-RPR-RAFTER-LAYER*)

  (princ "\n[RPRADD] Add a rafter line.")
  (setq p1 (getpoint     "\nFirst point: "))
  (setq p2 (if p1 (getpoint p1 "\nSecond point: ")))
  (cond
    ((not (and p1 p2))
     (princ "\n[RPRADD] Cancelled."))
    (T
     (setq mid    (mapcar '(lambda (a b) (/ (+ a b) 2.0)) p1 p2))
     (setq region (dsld-rpr-find-polygon-at mid))
     (setq pitch  (if region (dsld-rpr-pitch-of-region region)))
     (if (not pitch)
       (progn (initget 6)
              (setq pitch (getreal "\nPitch rise (e.g. 6 or 6.5 for 6/12 or 6.5/12): "))))
     (cond
       ((not pitch)
        ;; v1.8.0: Enter here used to crash on (float nil).
        (princ "\n[RPRADD] No pitch supplied.  Cancelled."))
       (T
        (setq len-flat    (distance p1 p2))
        (setq factor      (sqrt (+ 1.0 (/ (* (float pitch) (float pitch))
                                           144.0))))
        (setq len-true    (* len-flat factor))
        (setq len-true-ft (/ len-true 12.0))
        (setq rounded     (dsld-rpr-round-len-ft len-true-ft))
        (setq line (entmakex (list (cons 0 "LINE")
                                   (cons 8 *DSLD-RPR-RAFTER-LAYER*)
                                   (cons 10 p1)
                                   (cons 11 p2))))
        (cond
          (line
           ;; Tag rafter + its label as MANUAL so refreshes keep them
           ;; (v1.8.0 -- they used to vanish on the next regen).
           (dsld-rpr-tag-manual line)
           (setq lbl-before (entlast))
           (dsld-rpr-label-line-with-len line rounded)
           (setq lbl-after (entlast))
           (if (not (eq lbl-before lbl-after))
             (dsld-rpr-tag-manual lbl-after))))
        (princ (strcat "\n[RPRADD] Rafter added: "
                       (dsld-rpr-fmt-ft rounded) " on "
                       (dsld-rpr-fmt-pitch pitch) "/12."))))))

  (dsld-rpr-cleanup)
  (princ))

;; (RPRFILLNOTCH and its concave-vertex / notch-pair helpers removed
;;  in v1.6.0 -- user can grip-edit a polygon to add/move vertices,
;;  or run RPRDRAW to outline a clean replacement region by hand.)

;;-----------------------------------------------------------------------;;
;; Manual rafter pitch calc:  RPRCALCPITCH
;;-----------------------------------------------------------------------;;
;; Pick one or more existing rafter LINE entities, supply a pitch, and
;; the routine labels each line with its on-pitch length using the same
;; rounding rule, layer, font, and offset style as RPR's auto-generated
;; rafter labels.  Independent of any RPR scan -- works on any LINE
;; entities the user picks.
;;
(defun c:RPRCALCPITCH (/ oldecho oldlay pitch ss n i ent ed sp ep len
                         factor len-pitch len-pitch-ft rounded labeled
                         lbl-before lbl-after *error*)
  (vl-load-com)
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (dsld-rpr-stash 'clayer  (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  (dsld-rpr-ensure-layer *DSLD-RPR-LABEL-LAYER* *DSLD-RPR-PITCH-LAYER*)
  (dsld-rpr-ensure-text-style *DSLD-RPR-TEXT-STYLE*
                              *DSLD-RPR-TEXT-FONT*
                              *DSLD-RPR-TEXT-WIDTH*)

  (initget 6)
  (setq pitch (getreal "\n[RPRCALCPITCH] Pitch rise (e.g. 6 or 6.5 for 6/12 or 6.5/12): "))
  (princ "\n[RPRCALCPITCH] Select rafter line(s):")
  (setq ss (if pitch (ssget '((0 . "LINE")))))
  (cond
    ((or (not pitch) (not ss))
     (princ "\n[RPRCALCPITCH] Cancelled."))
    (T
     (setq factor (sqrt (+ 1.0 (/ (* (float pitch) (float pitch)) 144.0))))
     (setq n (sslength ss) i 0 labeled 0)
     (while (< i n)
       (setq ent (ssname ss i))
       (setq ed  (entget ent))
       (setq sp  (cdr (assoc 10 ed)))
       (setq ep  (cdr (assoc 11 ed)))
       (setq len           (distance sp ep))
       (setq len-pitch     (* len factor))
       (setq len-pitch-ft  (/ len-pitch 12.0))
       (setq rounded       (dsld-rpr-round-len-ft len-pitch-ft))
       ;; MANUAL-tag each label so scan refreshes don't delete it
       ;; (v1.8.0 -- user work survives the reactor now).
       (setq lbl-before (entlast))
       (dsld-rpr-label-line-with-len ent rounded)
       (setq lbl-after (entlast))
       (if (not (eq lbl-before lbl-after))
         (dsld-rpr-tag-manual lbl-after))
       (setq labeled (1+ labeled))
       (setq i (1+ i)))
     (princ (strcat "\n[RPRCALCPITCH] Labeled " (itoa labeled)
                    " line(s) on " (dsld-rpr-fmt-pitch pitch) "/12."))))

  (dsld-rpr-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; Final-output visibility:  RPRRESULT / RPRSHOW
;;-----------------------------------------------------------------------;;
;; RPRRESULT hides the design / preview layers (polygon outlines, color
;; fills, pitch verification labels, overlap warnings) so the drawing
;; shows only the rafters + length labels + hip/ridge/valley callouts on
;; top of the underlying DSLD layers.  Auto-runs at end of pass 2 of RPR.
;;
;; RPRSHOW turns every RPR-generated SSS layer back on (rafters, labels,
;; callouts, polygon outlines, fills, pitch labels, overlap warnings).
;; Use it if you want to inspect / re-edit the underlying preview after
;; RPR has finished.
;;-----------------------------------------------------------------------;;

(defun c:RPRRESULT ( / scan-layers)
  (vl-load-com)
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  ;; Hide truly design-only layers: color fills, overlap warnings,
  ;; and every RPR<N> polygon-outline layer across all scan slots.
  ;; PITCH-LBL-LAYER stays visible -- it hosts the "6/12" callouts
  ;; which are production output, not just verification text.
  (setq scan-layers (mapcar '(lambda (s) (nth 4 s)) *DSLD-RPR-SCANS*))
  (dsld-rpr-set-layers-on
    (append (list *DSLD-RPR-POLY-LAYER*
                  *DSLD-RPR-FILL-LAYER*
                  *DSLD-RPR-OVERLAP-LAYER*)
            scan-layers)
    :vlax-false)
  (dsld-rpr-set-layers-on
    (list *DSLD-RPR-RAFTER-LAYER*
          *DSLD-RPR-LABEL-LAYER*
          *DSLD-RPR-PITCH-LBL-LAYER*
          *DSLD-RPR-CHART-LAYER*)
    :vlax-true)
  (princ "\n[RPRRESULT] Design layers hidden.  RPRSHOW to bring them back.")
  (princ))

(defun c:RPRSHOW ( / scan-layers ss)
  (vl-load-com)
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  (setq scan-layers (mapcar '(lambda (s) (nth 4 s)) *DSLD-RPR-SCANS*))
  (dsld-rpr-set-layers-on
    (append (list *DSLD-RPR-POLY-LAYER*
                  *DSLD-RPR-FILL-LAYER*
                  *DSLD-RPR-PITCH-LBL-LAYER*
                  *DSLD-RPR-OVERLAP-LAYER*
                  *DSLD-RPR-RAFTER-LAYER*
                  *DSLD-RPR-LABEL-LAYER*)
            scan-layers)
    :vlax-true)
  ;; Push every fill hatch to the back (v1.9.1) so region boundaries
  ;; stay click-selectable for grip editing while fills are visible.
  ;; (Reactor-created fills skip draw-ordering; this catches them.)
  (setq ss (ssget "_X" (list '(0 . "HATCH")
                             (cons 8 *DSLD-RPR-FILL-LAYER*))))
  (if ss
    (vl-catch-all-apply
      '(lambda () (command "_.DRAWORDER" ss "" "_B"))))
  (princ "\n[RPRSHOW] All RPR layers visible.  Fills pushed behind")
  (princ "\n          boundaries -- click a boundary line to grip-edit;")
  (princ "\n          edits auto-regenerate that roof's rafters.")
  (princ))

;;-----------------------------------------------------------------------;;
;; Floating controller dialog:  RPRPANEL
;;-----------------------------------------------------------------------;;
;; Native DCL dialog -- works identically in AutoCAD and BricsCAD (DCL
;; is part of both stacks).  The DCL definition is written to a temp
;; file at runtime so we don't need to ship a separate .dcl file.
;;
;; DCL is modal-only, so we get the "stays open" feel by re-invoking
;; the dialog after each button click + command completes.  Click a
;; button -> dialog closes -> the matching command runs (with its own
;; prompts) -> dialog reappears for the next click.  Close button (or
;; Escape) exits the loop.
;;-----------------------------------------------------------------------;;

(setq *DSLD-RPR-PANEL-ACTION* nil)

;; Write the DCL definition to a temp file; return its path.  Building
;; line-by-line so the embedded double-quotes don't need escaping.
;; Layout: 4-line workflow text at top + 2-column action grid + Close.
;; Trimmed in v1.6.0 -- RPRSPLIT, RPRFILLNOTCH, RPRWATCH dropped from
;; the menu (RPRWATCH still callable but auto-installed by RPR; the
;; other two were removed entirely).
(defun dsld-rpr-write-panel-dcl ( / path f ver)
  (setq path (vl-filename-mktemp "rprpanel" nil ".dcl"))
  (setq ver  (if *DSLD-RPR-VERSION* *DSLD-RPR-VERSION* ""))
  (setq f    (open path "w"))
  (princ "rpr_panel : dialog {\n" f)
  (princ (strcat "  label = \"DSLD Roof Pitch Rafters  v" ver "\";\n") f)
  (princ "  : column {\n" f)
  ;; --- Workflow text (the "manual" part) -----------------------------
  (princ "    : boxed_column { label = \"Workflow\";\n" f)
  (princ "      : text { label = \"  1.  RPR -- window the roof; set OC spacing.\"; }\n" f)
  (princ "      : text { label = \"  2.  Rafters + areas + H/R/V + count chart render.\"; }\n" f)
  (princ "      : text { label = \"  3.  Click any missed areas; Enter ends loop.\"; }\n" f)
  (princ "      : text { label = \"  4.  Live mode on -- grip-edit anything; auto-regens.\"; }\n" f)
  (princ "      : text { label = \"  Fractional pitches OK (e.g. 6.5/12).\"; }\n" f)
  (princ "    }\n" f)
  ;; --- Action buttons (live links to commands) -----------------------
  (princ "    : boxed_row { label = \"Actions  (click to run)\";\n" f)
  (princ "      : column {\n" f)
  (princ "        : button { key = \"act_rpr\";       label = \"RPR\";          width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_refresh\";   label = \"RPRREFRESH\";   width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_area\";      label = \"RPRAREA\";      width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_fix\";       label = \"RPRFIX\";       width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_add\";       label = \"RPRADD\";       width = 14; fixed_width = true; }\n" f)
  (princ "      }\n" f)
  (princ "      : column {\n" f)
  (princ "        : button { key = \"act_calcpitch\"; label = \"RPRCALCPITCH\"; width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_show\";      label = \"RPRSHOW\";      width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_group\";     label = \"RPRGROUP\";     width = 14; fixed_width = true; }\n" f)
  (princ "        : button { key = \"act_update\";    label = \"RPRUPDATE\";    width = 14; fixed_width = true; }\n" f)
  (princ "      }\n" f)
  (princ "    }\n" f)
  ;; --- Close ----------------------------------------------------------
  (princ "    spacer_1;\n" f)
  (princ "    : row {\n" f)
  (princ "      : spacer { width = 1; }\n" f)
  (princ "      : button { key = \"close\"; label = \"Close\"; is_cancel = true; is_default = true; width = 12; fixed_width = true; }\n" f)
  (princ "      : spacer { width = 1; }\n" f)
  (princ "    }\n" f)
  (princ "  }\n" f)
  (princ "}\n" f)
  (close f)
  path)

;; Helper: wire one button to set the action global and close the dialog.
(defun dsld-rpr-wire (key cmd)
  (action_tile key (strcat "(setq *DSLD-RPR-PANEL-ACTION* \"" cmd "\") (done_dialog 1)")))

;; Single-shot: show the dialog ONCE, run the picked command, exit.
;; (We don't re-open the panel after the command finishes -- that would
;; (a) annoy the user with a popup between every action, and (b) break
;; RPR's two-pass workflow where pressing ENTER re-runs the previous
;; command to trigger Pass 2.  Panel must be the last-command-on-stack
;; ONLY long enough to dispatch one action.)
(defun c:RPRPANEL ( / dcl-path dcl-id cmd)
  (vl-load-com)
  (setq *DSLD-RPR-PANEL-ACTION* nil)
  (setq dcl-path (dsld-rpr-write-panel-dcl))
  (setq dcl-id   (load_dialog dcl-path))
  (cond
    ((< dcl-id 0)
     (princ "\n[RPRPANEL] load_dialog failed."))
    ((not (new_dialog "rpr_panel" dcl-id))
     (princ "\n[RPRPANEL] new_dialog failed.")
     (unload_dialog dcl-id))
    (T
     (dsld-rpr-wire "act_rpr"       "RPR")
     (dsld-rpr-wire "act_refresh"   "RPRREFRESH")
     (dsld-rpr-wire "act_area"      "RPRAREA")
     (dsld-rpr-wire "act_fix"       "RPRFIX")
     (dsld-rpr-wire "act_add"       "RPRADD")
     (dsld-rpr-wire "act_calcpitch" "RPRCALCPITCH")
     (dsld-rpr-wire "act_show"      "RPRSHOW")
     (dsld-rpr-wire "act_group"     "RPRGROUP")
     (dsld-rpr-wire "act_update"    "RPRUPDATE")
     (action_tile "close" "(done_dialog 0)")
     (start_dialog)
     (unload_dialog dcl-id)))
  (vl-catch-all-apply 'vl-file-delete (list dcl-path))
  (cond
    (*DSLD-RPR-PANEL-ACTION*
     (setq cmd *DSLD-RPR-PANEL-ACTION*)
     (setq *DSLD-RPR-PANEL-ACTION* nil)
     ;; Run the chosen command, then return -- do NOT reopen the panel.
     ;; v1.8.0: invoke the c:XXX function DIRECTLY.  AutoCAD cannot
     ;; launch LISP-defined commands through (command "..."), so the
     ;; panel buttons silently did nothing there; direct invocation
     ;; works identically on both CADs.
     (vl-catch-all-apply
       '(lambda () (eval (list (read (strcat "c:" cmd))))))))
  (princ))

;; RPRHELP is an alias for the panel -- the workflow text + clickable
;; "live link" buttons are baked into the same DCL dialog, so users
;; don't need a second command for help.
(defun c:RPRHELP ( ) (c:RPRPANEL))

;;-----------------------------------------------------------------------;;
;; Edit-friendly selection:  RPREDIT / RPRGROUP
;;-----------------------------------------------------------------------;;
;; AutoCAD: when polygons + fills are bound into a Group AND PICKSTYLE
;; bit 1 is on, clicking on the polygon selects the *group*, so the user
;; sees group-bbox grips instead of polyline vertex grips and cannot
;; grip-edit the polygon.  BricsCAD is more forgiving.  These two
;; commands let the user flip the behavior explicitly:
;;   RPREDIT  -> PICKSTYLE bit 1 OFF -- click selects single entity,
;;               polygon vertices are grip-editable (needed in AutoCAD)
;;   RPRGROUP -> PICKSTYLE bit 1 ON  -- click on polygon OR fill selects
;;               both at once (the original group behavior)
;; c:RPR pass 1 now leaves PICKSTYLE bit 1 OFF by default so editing
;; works in both CADs out of the box.
;;-----------------------------------------------------------------------;;

(defun c:RPREDIT ( / cur)
  (setq cur (getvar "PICKSTYLE"))
  ;; AutoLISP has no lognot; -2 = ...11111110 clears bit 0 via logand.
  (setvar "PICKSTYLE" (logand cur -2))
  (princ "\n[RPREDIT] Group selection OFF.  You can now grip-edit polygons.")
  (princ))

(defun c:RPRGROUP ( / cur)
  (setq cur (getvar "PICKSTYLE"))
  (setvar "PICKSTYLE" (logior cur 1))
  (princ "\n[RPRGROUP] Group selection ON.  Click polygon or fill selects both.")
  (princ))

;;-----------------------------------------------------------------------;;
;; Regenerate output after polygon edits:  RPRREFRESH
;;-----------------------------------------------------------------------;;
;; After Pass 2, if the user MOVES / GRIP-EDITS / RESHAPES a polygon,
;; the rafters + length labels + H/R/V callouts that were generated
;; against the OLD polygon position stay where they were -- they are
;; not associative.  RPRREFRESH wipes the derived output inside a
;; window and re-runs Pass 2's logic (process-single + label-all-
;; shared-edges) against the current polygon positions.
;;
;; Press Enter at the first-corner prompt to reuse the most recent
;; RPR / RPRREFRESH window (saved in *DSLD-RPR-LAST-BBOX*).
;;-----------------------------------------------------------------------;;

;; Wipe every derived entity (LINE/TEXT/CIRCLE/HATCH on the SSS layers,
;; but NOT the polygon outlines themselves) inside a bbox window.
;; v1.8.0: uses view-independent selection (ssget "_C" only sees what's
;; on screen -- a reactor refresh while zoomed elsewhere used to leave
;; all stale output behind), and SKIPS entities the user created via
;; RPRADD / RPRCALCPITCH (DSLD_RPR_MANUAL xdata).
(defun dsld-rpr-wipe-output-in-bbox (p1 p2 / filters f)
  (setq filters
        (list
          (list "LINE"       *DSLD-RPR-RAFTER-LAYER*)
          (list "TEXT"       *DSLD-RPR-LABEL-LAYER*)
          (list "CIRCLE"     *DSLD-RPR-LABEL-LAYER*)
          (list "HATCH"      *DSLD-RPR-FILL-LAYER*)
          (list "TEXT"       *DSLD-RPR-PITCH-LBL-LAYER*)
          (list "LWPOLYLINE" *DSLD-RPR-OVERLAP-LAYER*)))
  (foreach f filters
    (foreach e (dsld-rpr-ents-in-bbox (car f) (cadr f) p1 p2 0.0)
      (if (not (dsld-rpr-manual-p e))
        (entdel e))))
  ;; Chart text lives OUTSIDE the bbox (to the right); wipe its zone.
  (dsld-rpr-wipe-chart p1 p2))

;; Refresh every registered scan slot -- iterates *DSLD-RPR-SCANS*
;; and calls dsld-rpr-refresh-scan on each so multi-roof drawings
;; regenerate cleanly.  If no scans are registered (fresh drawing,
;; user hasn't run RPR yet), reports and exits.
(defun c:RPRREFRESH (/ n)
  (vl-load-com)
  ;; Rebuild the registry from persisted RPR<N> layers if the drawing
  ;; was scanned in an earlier session (v1.8.0).
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  (cond
    ((not *DSLD-RPR-SCANS*)
     (princ "\n[RPRREFRESH] No RPR scans registered.  Run RPR first."))
    (T
     (setq n (length *DSLD-RPR-SCANS*))
     (vl-catch-all-apply 'dsld-rpr-weld-neighbors)
     (foreach s *DSLD-RPR-SCANS*
       (dsld-rpr-refresh-scan s))
     ;; v1.9.15: re-arm live edit -- an APPLOAD of a new build drops the
     ;; reactor, and a manual refresh is exactly when the user notices.
     (dsld-rpr-ensure-watch)
     (princ (strcat "\n[RPRREFRESH] Refreshed " (itoa n)
                    " scan slot" (if (= n 1) "" "s") "."))))
  (princ))

;;-----------------------------------------------------------------------;;
;; Live edit mode:  RPRWATCH / RPRUNWATCH
;;-----------------------------------------------------------------------;;
;; Installs a vlr-command-reactor that, after every MOVE / STRETCH /
;; ROTATE / SCALE / ERASE / GRIPS / PEDIT / MIRROR / COPY command,
;; silently re-runs RPRREFRESH over the last RPR window.  So a user
;; grip-drags a polygon vertex, releases the mouse, and the rafters +
;; H/R/V callouts update automatically.
;;
;; Reactor is per-session (does NOT persist across drawing closes or
;; CAD restarts -- run RPRWATCH again after re-opening).  Set
;; *DSLD-RPR-WATCH-CMDS* to customize the trigger list.
;;-----------------------------------------------------------------------;;

;; Reloading this file used to nil the reactor handle unconditionally,
;; ORPHANING a live reactor (it kept firing with no way to remove it,
;; and a new one stacked on top -> double refresh per edit).  v1.8.0:
;; remove any live reactor we still know about before clearing.
;;
;; v1.9.15: ...but then the reload left live-edit mode SILENTLY OFF.
;; APPLOADing a new build is exactly what a user does before testing,
;; so every "I pulled a vertex and nothing updated" report started
;; here: rafters never regenerated, and the H/R/V callouts sat at their
;; old coordinates while the region moved out from under them -- which
;; reads as "the callouts disappeared".  Remember that it was on and
;; re-arm it at the bottom of this file.
(setq *DSLD-RPR-WATCH-WAS-ON* (and *DSLD-RPR-WATCH-REACTOR* T))
(if (and *DSLD-RPR-WATCH-REACTOR*
         (vl-catch-all-apply 'vlr-added-p (list *DSLD-RPR-WATCH-REACTOR*)))
  (vl-catch-all-apply 'vlr-remove (list *DSLD-RPR-WATCH-REACTOR*)))
(setq *DSLD-RPR-WATCH-REACTOR* nil)

;; Commands that trigger a silent refresh after they finish.  The
;; callback also fires on ANY command starting with "GRIP" (catches
;; every grip-drag variant on both CADs without enumerating names).
;;
;; v1.8.0: UNDO / U / REDO / MREDO REMOVED -- refreshing after an undo
;; created new entities that the NEXT undo had to chew through first,
;; so the user could never step backwards past a refresh.  Undo now
;; simply restores the pre-edit derived output, which is correct.
;; COPYCLIP / PASTECLIP also removed (clipboard ops don't reshape roof
;; polygons; they only caused pointless full-drawing refreshes).
(setq *DSLD-RPR-WATCH-CMDS*
  '("MOVE" "STRETCH" "ROTATE" "SCALE" "ERASE" "GRIPS"
    "PEDIT" "MIRROR" "COPY" "OFFSET" "ALIGN"
    "TRIM" "EXTEND" "FILLET" "CHAMFER" "BREAK" "JOIN"
    "EXPLODE" "ARRAY" "-ARRAY" "MSTRETCH" "MEDIT"))

;; Quiet variant of RPRREFRESH's core -- no prompts, no chatty princ.
;; Used by the reactor so each MOVE / STRETCH / etc. doesn't spam the
;; command line.  Wrapped by caller in vl-catch-all-apply.
;;
;; v1.8.0 hardening:
;;  * Entire path is command-free (entmake/entdel/entmod/ActiveX only)
;;    so it is LEGAL inside a reactor callback on AutoCAD.
;;  * Selection is view-independent (works while zoomed anywhere).
;;  * Does NOT touch layer visibility -- entmake creates fine on off
;;    layers, and forcing the fill layer back on was undoing the
;;    user's finished-view state after every edit.
;;  * Sets *DSLD-RPR-REFRESHING* so nothing re-triggers or attempts
;;    the (command)-based group binding.
;; Uses the current *DSLD-RPR-POLY-LAYER* for its polygon fetch; call
;; via dsld-rpr-refresh-scan to bind a specific scan's layer + OC.
(defun dsld-rpr-refresh-silent (p1 p2 / polys region pitch oc err
                                       bb w1 w2 margin)
  (setq *DSLD-RPR-REFRESHING* T)
  (setq oc *DSLD-RPR-LAST-OC*)
  ;; v1.9.15: fetch by region EXTENTS, not by a single reference point.
  ;; dsld-rpr-ents-in-bbox tests an LWPOLYLINE's FIRST VERTEX -- so
  ;; grip-dragging that one corner past the scan window dropped the whole
  ;; region out of the refresh: the wipe below still deleted its rafters
  ;; and nothing redrew them.  ("The rafters did not adjust.")
  (setq polys (dsld-rpr-polys-touching-bbox *DSLD-RPR-POLY-LAYER* p1 p2))
  ;; Wipe over the window UNION the extents of the regions about to be
  ;; regenerated, so a region that now overhangs the original window has
  ;; its old output cleared instead of left behind as a stale double.
  (setq w1 (list (min (car p1) (car p2)) (min (cadr p1) (cadr p2)) 0.0))
  (setq w2 (list (max (car p1) (car p2)) (max (cadr p1) (cadr p2)) 0.0))
  (setq margin (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
  (foreach region polys
    (setq bb (vl-catch-all-apply 'dsld-rpr-poly-bbox (list region)))
    (cond
      ((vl-catch-all-error-p bb) nil)
      (T
       (setq w1 (list (min (car  w1) (- (car  (car bb)) margin))
                      (min (cadr w1) (- (cadr (car bb)) margin)) 0.0))
       (setq w2 (list (max (car  w2) (+ (car  (cadr bb)) margin))
                      (max (cadr w2) (+ (cadr (cadr bb)) margin)) 0.0)))))
  (dsld-rpr-wipe-output-in-bbox w1 w2)
  ;; the chart is placed relative to the ORIGINAL window, so clear that
  ;; zone too -- the grown box would otherwise miss it and leave a
  ;; second chart behind
  (dsld-rpr-wipe-chart p1 p2)
  (cond
    (polys
     ;; v1.9.2: each region is caught individually.  The wipe above
     ;; already deleted ALL old output, so one region erroring must not
     ;; abort the rest -- that left every later region plus ALL H/R/V
     ;; callouts and the chart un-regenerated (the exact "rafters
     ;; update but callouts don't" field symptom on AutoCAD).  The
     ;; error is recorded for RPRDIAG instead of aborting.
     (foreach region polys
       (setq pitch (dsld-rpr-read-pitch region))
       (cond
         (pitch
          (setq err (vl-catch-all-apply
                      '(lambda ()
                         (dsld-rpr-process-single region pitch oc))))
          (if (vl-catch-all-error-p err)
            (setq *DSLD-RPR-LAST-REFRESH-ERR*
                  (strcat "process-single: "
                          (vl-catch-all-error-message err)))))))
     (setq err (vl-catch-all-apply
                 '(lambda () (dsld-rpr-label-all-shared-edges polys))))
     (if (vl-catch-all-error-p err)
       (setq *DSLD-RPR-LAST-REFRESH-ERR*
             (strcat "shared-edges: "
                     (vl-catch-all-error-message err))))
     ;; junction rafters at every H/R/V node (v1.9.14; entmake-only)
     (setq err (vl-catch-all-apply
                 '(lambda () (dsld-rpr-add-junction-rafters polys))))
     (if (vl-catch-all-error-p err)
       (setq *DSLD-RPR-LAST-REFRESH-ERR*
             (strcat "junction rafters: "
                     (vl-catch-all-error-message err))))))
  ;; Always re-render the chart so counts stay in sync with the
  ;; current rafter/H-R-V state, even if no polygons were found.
  ;; v1.9.15: caught like every other stage.  This was the last
  ;; unprotected call before the flag is cleared, and a throw here left
  ;; *DSLD-RPR-REFRESHING* stuck at T -- which silently gags the
  ;; live-edit reactor for the rest of the session.
  (setq err (vl-catch-all-apply '(lambda () (dsld-rpr-render-chart p1 p2))))
  (if (vl-catch-all-error-p err)
    (setq *DSLD-RPR-LAST-REFRESH-ERR*
          (strcat "chart: " (vl-catch-all-error-message err))))
  (setq *DSLD-RPR-REFRESHING* nil))

;;-----------------------------------------------------------------------;;
;; Vertex welding (v1.9.12, rewritten v1.9.15) -- shared EDGES stay joined
;;-----------------------------------------------------------------------;;
;; Region polygons meet along shared edges.  An H/R/V callout is only
;; earned where two regions have COLLINEAR OVERLAPPING edges -- that rule
;; is what stops a drip edge from being classified as a ridge.  So any
;; grip edit that pulls one region off its neighbor destroys the callout.
;;
;; After every render the vertices of every scan polygon are SNAPSHOTTED;
;; when an edit fires the reactor the diff names exactly which vertex
;; moved from where to where, and the neighbours that were attached
;; there are carried along BEFORE the refresh regenerates output.
;;
;; v1.9.12 welded only vertices that were COINCIDENT within 1".  On
;; production roofs that missed most joints:
;;   * T-junctions -- one plane's corner lands in the MIDDLE of the
;;     neighbour's long edge, so the neighbour has no vertex to move;
;;   * BPOLY traces (and seam-snapped regions) routinely leave matching
;;     corners an inch or three apart, outside the 1" match;
;;   * AutoCAD's mid-segment grip drag INSERTS a vertex, changing the
;;     count -- the old diff bailed out of that polygon entirely.
;; v1.9.15 welds on the SAME relation the callout uses:
;;   * corner weld -- a neighbour vertex within *DSLD-RPR-WELD-TOL* moves
;;     along;
;;   * edge weld -- the moved corner sat ON a neighbour EDGE, so a vertex
;;     is INSERTED there and the neighbour deforms with it;
;;   * a mid-segment vertex ADD is treated as a move from its foot on the
;;     original edge, so bulging an edge carries the neighbour too.
;; Moving a WHOLE region (every vertex displaced by the same delta) is a
;; deliberate relocation and is still NOT welded.

;; Replace the idx-th group-10 vertex of an LWPOLYLINE via entmod.
(defun dsld-rpr-poly-move-vertex (poly idx newpt / data out i x)
  (setq data (entget poly) out '() i 0)
  (foreach x data
    (cond
      ((and (= (car x) 10) (= i idx))
       (setq out (cons (cons 10 (list (car newpt) (cadr newpt))) out))
       (setq i (1+ i)))
      ((= (car x) 10)
       (setq out (cons x out))
       (setq i (1+ i)))
      (T (setq out (cons x out)))))
  (entmod (reverse out)))

;; Snapshot the vertex lists of every polygon on every scan layer.
(defun dsld-rpr-vtx-snapshot ( / lays out l ss e)
  (setq lays '())
  (foreach s *DSLD-RPR-SCANS*
    (if (not (member (nth 4 s) lays)) (setq lays (cons (nth 4 s) lays))))
  (if (and *DSLD-RPR-POLY-LAYER* (not (member *DSLD-RPR-POLY-LAYER* lays)))
    (setq lays (cons *DSLD-RPR-POLY-LAYER* lays)))
  (setq out '())
  (foreach l lays
    (setq ss (ssget "_X" (list '(0 . "LWPOLYLINE") (cons 8 l))))
    (foreach e (dsld-rpr-ss->list ss)
      (setq out (cons (cons e (dsld-rpr-poly-vertices e)) out))))
  (setq *DSLD-RPR-VTX-CACHE* out))

;; Insert a vertex into an LWPOLYLINE immediately AFTER vertex index k
;; (v1.9.15).  The entity data is split into head / per-vertex groups /
;; tail so the new (10) group lands inside the vertex run and never
;; between the extrusion or XDATA groups -- AutoCAD rejects that, and it
;; would also strand the region's pitch tag.  The (90) vertex count is
;; bumped in the head.
(defun dsld-rpr-poly-insert-after (poly k pt / data head verts tail cur
                                          x started done out i)
  (setq data (entget poly))
  (setq head '() verts '() tail '() cur nil started nil done nil)
  (foreach x data
    (cond
      (done (setq tail (cons x tail)))
      ((= (car x) 10)
       (if cur (setq verts (cons (reverse cur) verts)))
       (setq cur (list x))
       (setq started T))
      ((and started (member (car x) '(40 41 42 91)))
       (setq cur (cons x cur)))
      (started                          ; first group past the vertex run
       (if cur (setq verts (cons (reverse cur) verts)))
       (setq cur nil done T)
       (setq tail (cons x tail)))
      (T (setq head (cons x head)))))
  (if cur (setq verts (cons (reverse cur) verts)))
  (setq verts (reverse verts))
  (setq head  (reverse head))
  (setq tail  (reverse tail))
  (setq head (mapcar '(lambda (g) (if (= (car g) 90) (cons 90 (1+ (cdr g))) g))
                     head))
  (setq out '() i 0)
  (foreach x verts
    (setq out (append out x))
    (if (= i k)
      (setq out (append out (list (cons 10 (list (car pt) (cadr pt)))))))
    (setq i (1+ i)))
  (entmod (append head out tail)))

;; OLD and NEW differ by exactly one INSERTED vertex (AutoCAD's
;; mid-segment grip drag).  Returns the inserted index in NEW, else nil.
(defun dsld-rpr-added-vertex-index (old new / n i k ok j)
  (setq n (length old) i 0 k nil)
  (while (and (< i n) (not k))
    (if (> (distance (nth i old) (nth i new)) 0.5) (setq k i))
    (setq i (1+ i)))
  (if (not k) (setq k n))               ; appended after the last vertex
  (setq ok T j k)
  (while (< j n)
    (if (> (distance (nth j old) (nth (1+ j) new)) 0.5) (setq ok nil))
    (setq j (1+ j)))
  (if ok k nil))

;; Carry ONE vertex move (oldpt -> newpt, made on SRC) into every other
;; live scan polygon that was attached at oldpt.  Polygons listed in
;; SRCS were edited by the user themselves and are left alone.
;; Returns the number of neighbour vertices moved or inserted.
(defun dsld-rpr-weld-one (src oldpt newpt srcs / welded other poly cur n
                                 j hit a b foot k)
  (setq welded 0)
  (foreach other *DSLD-RPR-VTX-CACHE*
    (setq poly (car other))
    (cond
      ((eq poly src) nil)
      ((member poly srcs) nil)          ; user moved this one on purpose
      ((not (entget poly)) nil)
      (T
       (setq cur (dsld-rpr-poly-vertices poly))
       (setq n (length cur) j 0 hit nil)
       ;; --- corner weld: a vertex of this region sat on oldpt --------
       (while (< j n)
         (cond
           ((and (not hit)
                 (< (distance (nth j cur) oldpt) *DSLD-RPR-WELD-TOL*))
            (dsld-rpr-poly-move-vertex poly j newpt)
            (setq welded (1+ welded) hit T)))
         (setq j (1+ j)))
       ;; --- edge weld: oldpt sat ON an edge (T-junction) -------------
       ;; No vertex to move, so INSERT one at the new spot; the
       ;; neighbour deforms with the edit instead of separating.
       (cond
         (hit nil)
         (T
          (setq j 0 k nil)
          (while (< j n)
            (setq a (nth j cur) b (nth (rem (1+ j) n) cur))
            (setq foot (dsld-rpr-project-to-seg oldpt a b))
            (if (and (not k)
                     (< (distance oldpt foot) *DSLD-RPR-WELD-TOL*)
                     (> (distance foot a) 2.0)
                     (> (distance foot b) 2.0))
              (setq k j))
            (setq j (1+ j)))
          (cond
            (k
             (dsld-rpr-poly-insert-after poly k newpt)
             (setq welded (1+ welded)))))))))
  welded)

;; Diff every cached polygon against its current vertices and return the
;; list of genuine vertex edits as (poly oldpt newpt).  Collected in a
;; separate pass so that welding a neighbour can never be mistaken for a
;; user edit of that neighbour on a later iteration (which used to
;; cascade a single drag across the whole roof).
(defun dsld-rpr-collect-edits ( / events pair poly old new n moved i
                                 whole d0 deltas mv k ins)
  (setq events '())
  (foreach pair *DSLD-RPR-VTX-CACHE*
    (setq poly (car pair) old (cdr pair))
    (cond
      ((not (entget poly)) nil)                       ; deleted region
      (T
       (setq new (dsld-rpr-poly-vertices poly))
       (setq n (length old))
       (cond
         ;; ---- same count: ordinary grip drag / stretch -------------
         ((= (length new) n)
          (setq moved '() i 0)
          (while (< i n)
            (if (> (distance (nth i old) (nth i new)) 0.5)
              (setq moved (cons i moved)))
            (setq i (1+ i)))
          (cond
            ((not moved) nil)
            (T
             ;; whole-region relocation?  every vertex moved by the
             ;; same delta -> deliberate MOVE, don't drag neighbors
             (setq whole (= (length moved) n))
             (cond
               (whole
                (setq d0 (mapcar '- (nth 0 new) (nth 0 old)))
                (foreach i moved
                  (setq deltas (mapcar '- (nth i new) (nth i old)))
                  (if (> (distance deltas d0) 0.5) (setq whole nil)))))
             (cond
               (whole nil)
               (T
                (foreach mv moved
                  (setq events (cons (list poly (nth mv old) (nth mv new))
                                     events))))))))
         ;; ---- one vertex ADDED: AutoCAD mid-segment grip drag ------
         ;; The neighbour was attached along the ORIGINAL edge, so the
         ;; weld origin is the new corner's foot on that edge.
         ((= (length new) (1+ n))
          (setq k (dsld-rpr-added-vertex-index old new))
          (cond
            (k
             (setq ins (nth k new))
             (setq events
                   (cons (list poly
                               (dsld-rpr-project-to-seg
                                 ins
                                 (nth (rem (+ (1- k) n) n) old)
                                 (nth (rem k n) old))
                               ins)
                         events)))))
         (T nil)))))                    ; vertex removed -- nothing to do
  (reverse events))

;; Weld pass: propagate every genuine vertex edit to the regions that
;; were attached there.  Returns the number of neighbour vertices moved.
(defun dsld-rpr-weld-neighbors ( / events srcs ev welded)
  (setq events (dsld-rpr-collect-edits))
  (setq srcs (mapcar 'car events))
  (setq welded 0)
  (foreach ev events
    (setq welded (+ welded (dsld-rpr-weld-one (car ev) (cadr ev)
                                              (caddr ev) srcs))))
  (if (> welded 0)
    (dsld-rpr-dbg (strcat "weld: moved " (itoa welded)
                          " neighbor vertex(es) for "
                          (itoa (length events)) " edit(s)")))
  welded)

;; Refresh ONE scan slot.  Temporarily binds *DSLD-RPR-POLY-LAYER* +
;; *DSLD-RPR-LAST-OC* to that scan's stored values so
;; dsld-rpr-refresh-silent (which reads those globals) walks the right
;; polygons + spacing.  Restores globals on exit even if refresh errors.
(defun dsld-rpr-refresh-scan (scan-tuple / saved-lay saved-oc p1 p2 e)
  (cond
    ((not scan-tuple) nil)
    (T
     (setq saved-lay *DSLD-RPR-POLY-LAYER*)
     (setq saved-oc  *DSLD-RPR-LAST-OC*)
     (setq p1        (nth 1 scan-tuple))
     (setq p2        (nth 2 scan-tuple))
     (setq *DSLD-RPR-POLY-LAYER* (nth 4 scan-tuple))
     (setq *DSLD-RPR-LAST-OC*    (nth 3 scan-tuple))
     (setq e (vl-catch-all-apply
               '(lambda () (dsld-rpr-refresh-silent p1 p2))))
     (setq *DSLD-RPR-POLY-LAYER* saved-lay)
     (setq *DSLD-RPR-LAST-OC*    saved-oc)
     ;; refresh-silent clears this on success; force-clear on error so
     ;; one failed refresh can't permanently disable the watch.
     (setq *DSLD-RPR-REFRESHING* nil)
     ;; keep the weld snapshot current after every regeneration
     (vl-catch-all-apply 'dsld-rpr-vtx-snapshot)
     (cond
       ((vl-catch-all-error-p e)
        ;; Persist the message: princ inside a reactor callback is easy
        ;; to miss (and may not render at all on AutoCAD).  RPRDIAG
        ;; reports the last one recorded.
        (setq *DSLD-RPR-LAST-REFRESH-ERR*
              (strcat "scan " (itoa (car scan-tuple)) ": "
                      (vl-catch-all-error-message e)))
        (princ (strcat "\n[RPR] Scan refresh error: "
                       (vl-catch-all-error-message e))))))))

;; Reactor callback.  params is (cmdname) for :vlr-commandEnded.
;; Fires per-scan refresh if the command name is in the explicit watch
;; list OR starts with "GRIP" (any grip-drag variant, name varies by
;; CAD).  Iterates every scan slot so multi-roof drawings keep every
;; scan in sync -- not just the most recent one.
;;
;; v1.8.0: the refresh path is fully command-free (entmake / entdel /
;; ActiveX only), which is what makes running it inside a reactor
;; callback legal on AutoCAD.  *DSLD-RPR-REFRESHING* guards against
;; reentry if a future change ever makes the refresh end a command.
(defun dsld-rpr-on-command-ended (reactor params / cmd fired)
  (setq cmd (strcase (car params)))
  (setq fired (and (not *DSLD-RPR-REFRESHING*)
                   (or (member cmd *DSLD-RPR-WATCH-CMDS*)
                       (eq 0 (vl-string-search "GRIP" cmd)))
                   *DSLD-RPR-SCANS*
                   T))
  ;; v1.9.15: remember the last 12 command names the reactor SAW and
  ;; whether each one triggered a refresh.  When a field report says
  ;; "I pulled a vertex and nothing happened", RPRDIAG now answers the
  ;; only question that matters -- did the edit ever reach us, and under
  ;; what command name -- instead of us guessing.
  (setq *DSLD-RPR-LAST-CMDS*
        (cons (strcat cmd (if fired " -> refresh" " -> ignored"))
              *DSLD-RPR-LAST-CMDS*))
  (if (> (length *DSLD-RPR-LAST-CMDS*) 12)
    (setq *DSLD-RPR-LAST-CMDS*
          (reverse (cdr (reverse *DSLD-RPR-LAST-CMDS*)))))
  (cond
    (fired
     ;; v1.9.12: weld FIRST -- neighbors that shared the edited corner
     ;; follow it, so shared edges never separate and H/R/V callouts
     ;; survive the regeneration.  entmod-only -> reactor-legal.
     (vl-catch-all-apply 'dsld-rpr-weld-neighbors)
     (foreach s *DSLD-RPR-SCANS*
       (dsld-rpr-refresh-scan s)))))

;; Install the live-edit reactor unless one is already live (v1.9.15 --
;; single definition; c:RPR, c:RPRWATCH, every command that regenerates
;; output, and the end-of-file reload hook all go through here).
;; Returns T if watching after the call.
(defun dsld-rpr-ensure-watch ( / live)
  (vl-load-com)
  (setq live
        (and *DSLD-RPR-WATCH-REACTOR*
             (not (vl-catch-all-error-p
                    (vl-catch-all-apply 'vlr-added-p
                                        (list *DSLD-RPR-WATCH-REACTOR*))))))
  (cond
    (live T)
    (T
     (setq *DSLD-RPR-WATCH-REACTOR*
           (vl-catch-all-apply
             'vlr-command-reactor
             (list
               "DSLD-RPR-Watch"
               ;; v1.9.4: a grip drag terminated by Enter/Esc, or a MOVE
               ;; the user Escs, ends via commandCancelled/Failed rather
               ;; than commandEnded on some CADs -- wire all three to the
               ;; same callback so a completed edit never silently skips
               ;; the regen.  The callback filters by command name, so a
               ;; genuine no-op cancel just re-derives identical output.
               '((:vlr-commandEnded     . dsld-rpr-on-command-ended)
                 (:vlr-commandCancelled . dsld-rpr-on-command-ended)
                 (:vlr-commandFailed    . dsld-rpr-on-command-ended)))))
     (if (vl-catch-all-error-p *DSLD-RPR-WATCH-REACTOR*)
       (setq *DSLD-RPR-WATCH-REACTOR* nil))
     (and *DSLD-RPR-WATCH-REACTOR* T))))

(defun c:RPRWATCH ( )
  (vl-load-com)
  (cond
    (*DSLD-RPR-WATCH-REACTOR*
     (princ "\n[RPRWATCH] Already watching.  Run RPRUNWATCH first to reset."))
    ((not *DSLD-RPR-LAST-BBOX*)
     (princ "\n[RPRWATCH] Run RPR (or RPRREFRESH) at least once first --")
     (princ "\n           need a window to know what area to regenerate."))
    (T
     (dsld-rpr-ensure-watch)
     (princ "\n[RPRWATCH] Watching.  Rafters + H/R/V callouts will auto-")
     (princ "\n           regenerate after each MOVE / STRETCH / GRIPS /")
     (princ "\n           ROTATE / SCALE / ERASE / PEDIT / MIRROR / COPY.")
     (princ "\n           Run RPRUNWATCH to stop.")))
  (princ))

(defun c:RPRUNWATCH ( )
  (vl-load-com)
  (cond
    ((not *DSLD-RPR-WATCH-REACTOR*)
     (princ "\n[RPRUNWATCH] Not currently watching."))
    (T
     (vl-catch-all-apply 'vlr-remove (list *DSLD-RPR-WATCH-REACTOR*))
     (setq *DSLD-RPR-WATCH-REACTOR* nil)
     (princ "\n[RPRUNWATCH] Stopped watching.  Run RPRREFRESH manually as needed.")))
  (princ))

;;-----------------------------------------------------------------------;;
;; Manually draw + add a region:  RPRDRAW
;;-----------------------------------------------------------------------;;
;; Some roof areas can't be auto-traced by BPOLY (gaps too big, lines
;; on a layer we excluded, etc.).  RPRDRAW lets the user outline a
;; region by clicking vertices (Enter to close), supply a pitch, and
;; the routine creates a properly-tagged polygon -- cycled outline
;; color, XDATA pitch tag -- attached to the scan slot whose bbox
;; contains it (or a brand-new slot), then regenerates that scan so
;; rafters + H/R/V + chart appear immediately (v1.8.0: it used to
;; reference the removed two-pass PENDING machinery and told the user
;; to run other commands by hand).
;;-----------------------------------------------------------------------;;

(defun c:RPRDRAW (/ oldecho oldlay pts pt pitch region bb margin
                    scan-tuple scan-id *error*)
  (vl-load-com)
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (dsld-rpr-stash 'clayer  (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  ;; Make sure the layers + text style exist (user may run RPRDRAW
  ;; without having run RPR first).
  (dsld-rpr-ensure-layer *DSLD-RPR-FILL-LAYER*      (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-layer *DSLD-RPR-PITCH-LBL-LAYER* *DSLD-RPR-PITCH-LAYER*)
  (dsld-rpr-ensure-text-style *DSLD-RPR-TEXT-STYLE*
                              *DSLD-RPR-TEXT-FONT*
                              *DSLD-RPR-TEXT-WIDTH*)
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  (princ "\n[RPRDRAW] Outline a region.  Click vertices; Enter to close.")
  (setq pts '())
  (while (setq pt (getpoint (if pts (last pts))
                            (if pts "\nNext vertex [Enter=close]: "
                                    "\nFirst vertex: ")))
    (setq pts (append pts (list pt))))
  (cond
    ((< (length pts) 3)
     (princ "\n[RPRDRAW] Need at least 3 vertices.  Cancelled."))
    (T
     (initget 6)              ; positive real, no zero
     (setq pitch (getreal "\n[RPRDRAW] Pitch rise (e.g. 6 or 6.5 for 6/12 or 6.5/12): "))
     (cond
       ((not pitch)
        (princ "\n[RPRDRAW] No pitch.  Cancelled."))
       (T
        ;; Attach to the scan slot containing the outline, or open a
        ;; new one (same slot logic as RPRAREA).
        (setq scan-tuple
              (dsld-rpr-find-overlapping-scan (car pts) (cadr pts)))
        (cond
          (scan-tuple
           (setq scan-id (car scan-tuple)))
          (T
           (setq *DSLD-RPR-SCAN-COUNTER* (1+ *DSLD-RPR-SCAN-COUNTER*))
           (setq scan-id *DSLD-RPR-SCAN-COUNTER*)))
        (dsld-rpr-ensure-layer (dsld-rpr-scan-layer scan-id)
                                (car *DSLD-RPR-ROOF-LAYERS*))
        (setq region (dsld-rpr-make-lwpoly
                       pts (dsld-rpr-scan-layer scan-id)))
        (cond
          ((not region)
           (princ "\n[RPRDRAW] Failed to create polygon."))
          (T
           (setq bb (dsld-rpr-poly-bbox region))
           (setq margin (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
           (setq scan-tuple
                 (dsld-rpr-register-scan
                   scan-id
                   (list (- (car  (car bb)) margin)
                         (- (cadr (car bb)) margin) 0.0)
                   (list (+ (car  (cadr bb)) margin)
                         (+ (cadr (cadr bb)) margin) 0.0)
                   *DSLD-RPR-LAST-OC*))
           (dsld-rpr-tag-pitch region pitch)
           (dsld-rpr-tint-poly region)
           (dsld-rpr-refresh-scan scan-tuple)
           (princ (strcat "\n[RPRDRAW] Added " (itoa (length pts))
                          "-vertex region at pitch "
                          (dsld-rpr-fmt-pitch pitch) "/12 (scan "
                          (itoa scan-id) ")."))))))))
  (dsld-rpr-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; Capture a missed area AFTER the scan:  RPRMISS
;;-----------------------------------------------------------------------;;
;; c:RPR ends with a "click missed area" loop, but once the user presses
;; Enter that loop is gone -- and a missed plane is usually only noticed
;; later, while checking the chart.  Re-running RPR rescans everything;
;; RPRDRAW makes the user trace the outline by hand.  Neither is what
;; "I just need to add that one area" should cost.
;;
;; RPRMISS re-enters exactly the capture ladder c:RPR uses, any time:
;;   pass 1  normal trace, dashed sub-roof linework hidden (scan rules)
;;   pass 2a diagonal dashes restored  (valley/hip-bounded zones)
;;   pass 2b all dashes restored       (dormer / under-roof strips)
;;   pass 3  outline it by corner clicks -- always available, so the
;;           user is NEVER left without a way to capture what they see
;; The captured region joins the scan slot under the click (its bbox is
;; grown to fit), gets the pitch the user gives it, and that slot is
;; refreshed so rafters + H/R/V + chart account for it immediately.
;;-----------------------------------------------------------------------;;

(defun c:RPRMISS (/ pt scan-tuple sp1 sp2 hp1 hp2 roof-layers
                    roof-lay-filter max-region-area md-out-lays
                    hidden-dashed region pitch mo-pts mo-pt md-iso
                    n-added saved-lay saved-oc bb margin *error*)
  (vl-load-com)
  (princ (strcat "\n[RPRMISS v" *DSLD-RPR-VERSION* "]"))
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (dsld-rpr-stash 'clayer  (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  (cond
    ((not *DSLD-RPR-SCANS*)
     (princ "\n[RPRMISS] No RPR scans registered.  Run RPR first."))
    (T
     (setq roof-layers (if *DSLD-RPR-STRICT-LAYERS*
                         *DSLD-RPR-ROOF-LAYERS*
                         *DSLD-RPR-ROOF-LAYERS*))
     (setq roof-lay-filter (apply 'strcat (dsld-rpr-comma-join roof-layers)))
     (setq md-out-lays (list *DSLD-RPR-RAFTER-LAYER* *DSLD-RPR-LABEL-LAYER*
                             *DSLD-RPR-FILL-LAYER*   *DSLD-RPR-PITCH-LBL-LAYER*
                             *DSLD-RPR-CHART-LAYER*  *DSLD-RPR-OVERLAP-LAYER*))
     (setq n-added 0)
     (princ (strcat "\n[RPRMISS] Tracing on: " roof-lay-filter))
     (while (setq pt (getpoint "\n[RPRMISS] Click missed area (Enter=done): "))
       ;; --- which scan slot owns this click? --------------------------
       (setq scan-tuple nil)
       (foreach s *DSLD-RPR-SCANS*
         (if (and (not scan-tuple)
                  (dsld-rpr-pt-in-bbox pt (nth 1 s) (nth 2 s)))
           (setq scan-tuple s)))
       (if (not scan-tuple) (setq scan-tuple (car *DSLD-RPR-SCANS*)))
       (setq sp1 (nth 1 scan-tuple) sp2 (nth 2 scan-tuple))
       (setq max-region-area
             (* 0.7 (abs (* (- (car sp2) (car sp1))
                            (- (cadr sp2) (cadr sp1))))))
       ;; Bind the slot's polygon layer + spacing for the trace, exactly
       ;; as dsld-rpr-refresh-scan does, and restore after.
       (setq saved-lay *DSLD-RPR-POLY-LAYER*)
       (setq saved-oc  *DSLD-RPR-LAST-OC*)
       (setq *DSLD-RPR-POLY-LAYER* (nth 4 scan-tuple))
       (setq *DSLD-RPR-LAST-OC*    (nth 3 scan-tuple))
       ;; Blind every trace to RPR's own output (rafters, callouts,
       ;; fills are perfectly good BPOLY boundaries and would trace a
       ;; sliver between two rafters).  Stashed so Esc restores them.
       (dsld-rpr-set-layers-on md-out-lays :vlax-false)
       (dsld-rpr-stash 'md-off md-out-lays)
       ;; Isolate to the roof layers for the trace, exactly as the main
       ;; scan does -- otherwise BPOLY happily closes the click against a
       ;; wall, a dimension or a hatch boundary and returns a shape that
       ;; has nothing to do with the roof.
       (setq md-iso (dsld-rpr-isolate-layers
                      (append roof-layers (list *DSLD-RPR-POLY-LAYER*))))
       (dsld-rpr-stash 'md-iso md-iso)
       ;; Dashed linework is hidden only NEAR the click: ssget "_C" is
       ;; view-dependent, and the whole scan window is rarely on screen
       ;; when the user is zoomed in on the area they are fixing.
       (setq hp1 (list (- (car pt) 600.0) (- (cadr pt) 600.0) 0.0))
       (setq hp2 (list (+ (car pt) 600.0) (+ (cadr pt) 600.0) 0.0))
       (setq hidden-dashed (dsld-rpr-hide-non-solid-in-bbox hp1 hp2))
       (dsld-rpr-stash 'hidden hidden-dashed)
       ;; --- pass 1: scan rules ---------------------------------------
       (setq region (dsld-rpr-bpoly-auto-close pt roof-lay-filter))
       (if (and region (dsld-rpr-missed-region-bad-p region max-region-area))
         (progn (entdel region) (setq region nil)))
       ;; --- pass 2a: diagonal dashes back (valley/hip zones) ----------
       (cond
         ((not region)
          (dsld-rpr-restore-diagonals hidden-dashed)
          (setq region (dsld-rpr-bpoly-auto-close pt roof-lay-filter))
          (if (and region
                   (dsld-rpr-missed-region-bad-p region max-region-area))
            (progn (entdel region) (setq region nil)))))
       ;; --- pass 2b: all dashes back (dormer / under-roof strips) -----
       (cond
         ((not region)
          (dsld-rpr-restore-visible hidden-dashed)
          (setq region (dsld-rpr-bpoly-auto-close pt roof-lay-filter))
          (if (and region
                   (dsld-rpr-missed-region-bad-p region max-region-area))
            (progn (entdel region) (setq region nil)))))
       ;; lift the trace-only isolation before any further prompting
       (dsld-rpr-restore-layers md-iso)
       (setq md-iso nil)
       (dsld-rpr-set-layers-on md-out-lays :vlax-true)
       ;; --- pass 3: outline by corner clicks -- always available -----
       (cond
         ((not region)
          (princ "\n[RPRMISS] Couldn't auto-trace there.  Outline it instead:")
          (setq mo-pts '())
          (while (setq mo-pt
                    (getpoint (if mo-pts (last mo-pts))
                              (if mo-pts "\nNext corner [Enter=close]: "
                                         "\nFirst corner of area: ")))
            (setq mo-pts (append mo-pts (list mo-pt))))
          (if (>= (length mo-pts) 3)
            (setq region (dsld-rpr-make-lwpoly mo-pts *DSLD-RPR-POLY-LAYER*))
            (princ "\n[RPRMISS] (need 3+ corners -- skipped)"))))
       ;; --- put the dashed linework back -----------------------------
       (dsld-rpr-restore-visible hidden-dashed)
       (setq hidden-dashed nil)
       ;; --- pitch, tag, register, refresh ----------------------------
       (cond
         (region
          (initget 6)
          (setq pitch (getreal "\nPitch (e.g. 6 or 6.5): "))
          (cond
            ((not pitch)
             (entdel region)
             (princ "\n[RPRMISS] No pitch given -- area discarded."))
            (T
             (entmod (subst (cons 8 *DSLD-RPR-POLY-LAYER*)
                            (assoc 8 (entget region))
                            (entget region)))
             (dsld-rpr-tag-pitch region pitch)
             (dsld-rpr-tint-poly region)
             ;; grow the slot bbox so a region captured past the original
             ;; scan window still gets refreshed with everything else
             (setq bb (dsld-rpr-poly-bbox region))
             (setq margin (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
             (setq scan-tuple
                   (dsld-rpr-register-scan
                     (car scan-tuple)
                     (list (- (car  (car bb)) margin)
                           (- (cadr (car bb)) margin) 0.0)
                     (list (+ (car  (cadr bb)) margin)
                           (+ (cadr (cadr bb)) margin) 0.0)
                     (nth 3 scan-tuple)))
             (setq n-added (1+ n-added))
             (princ (strcat "\n[RPRMISS] Captured "
                            (rtos (/ (dsld-rpr-poly-area-flat region) 144.0) 2 0)
                            " SF at pitch " (dsld-rpr-fmt-pitch pitch)
                            "/12 (scan " (itoa (car scan-tuple)) ")."))
             (setq *DSLD-RPR-POLY-LAYER* saved-lay)
             (setq *DSLD-RPR-LAST-OC*    saved-oc)
             (dsld-rpr-refresh-scan scan-tuple)))))
       (setq *DSLD-RPR-POLY-LAYER* saved-lay)
       (setq *DSLD-RPR-LAST-OC*    saved-oc)
       (setq region nil))
     (dsld-rpr-ensure-watch)
     (princ (strcat "\n[RPRMISS] Done -- " (itoa n-added)
                    " area" (if (= n-added 1) "" "s") " added."))))
  (dsld-rpr-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; Bridge an open area:  RPRAREA
;;-----------------------------------------------------------------------;;
;; For roof areas that aren't fully enclosed by drawn polylines (back
;; porches with the front open, sheds with the entry side unfilled,
;; etc.).  User clicks the two endpoints of the OPEN side, clicks
;; inside the region, and supplies a pitch.  The routine drops a
;; temporary LINE bridging the open side, runs BPOLY at the interior
;; click, then removes the temp line.  The resulting polygon is
;; tagged + tinted + rendered exactly like an auto-traced region.
;;-----------------------------------------------------------------------;;

(defun c:RPRAREA (/ oldecho oldlay p1 p2 pt pitch
                    tmp-line region roof-lay bb margin
                    scan-tuple scan-id *error*)
  (vl-load-com)
  (setq *error* dsld-rpr-cmd-error)
  (setq *DSLD-RPR-CLEANUP* nil)
  (dsld-rpr-stash 'cmdecho (getvar "CMDECHO"))
  (dsld-rpr-stash 'clayer  (getvar "CLAYER"))
  (setvar "CMDECHO" 0)
  (setq roof-lay (car *DSLD-RPR-ROOF-LAYERS*))
  (dsld-rpr-ensure-layer *DSLD-RPR-FILL-LAYER*      roof-lay)
  (dsld-rpr-ensure-layer *DSLD-RPR-PITCH-LBL-LAYER* *DSLD-RPR-PITCH-LAYER*)
  (dsld-rpr-ensure-text-style *DSLD-RPR-TEXT-STYLE*
                              *DSLD-RPR-TEXT-FONT*
                              *DSLD-RPR-TEXT-WIDTH*)
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  (princ "\n[RPRAREA] Bridge an open area (e.g. back porch).")
  (setq p1 (getpoint  "\nFirst endpoint of the OPEN side: "))
  (setq p2 (if p1 (getpoint p1 "\nSecond endpoint of the OPEN side: ")))
  (setq pt (if p2 (getpoint    "\nClick inside the (now-closed) area: ")))
  (initget 6)
  (setq pitch (if pt (getreal   "\nPitch (e.g. 6 or 6.5): ")))
  (cond
    ((not pitch)
     (princ "\n[RPRAREA] Cancelled."))
    (T
     ;; --- Drop a temp bridging LINE on the roof structure layer so
     ;; --- BPOLY has a closed boundary to trace around.
     (setvar "CLAYER" roof-lay)
     (setq tmp-line
           (entmakex (list (cons 0 "LINE")
                           (cons 8 roof-lay)
                           (cons 10 p1)
                           (cons 11 p2))))
     ;; --- Run BPOLY at the interior click.
     (setq region (dsld-rpr-bpoly-at pt))
     ;; --- Remove the temp line (whether BPOLY succeeded or not).
     (if tmp-line (entdel tmp-line))
     (cond
       ((not region)
        (princ "\n[RPRAREA] BPOLY still failed.")
        (princ "\n           Try RPRDRAW to outline vertex-by-vertex."))
       (T
        ;; --- Attach the region to a scan slot (v1.8.0).  Old code
        ;; refreshed *DSLD-RPR-LAST-BBOX* unconditionally: a porch
        ;; OUTSIDE the last window got a polygon but no rafters, and
        ;; the next reactor pass deleted its output entirely.  Now:
        ;; region inside an existing scan -> join it (bbox unions);
        ;; otherwise -> brand-new scan slot around the region.
        (setq bb (dsld-rpr-poly-bbox region))
        (setq scan-tuple
              (dsld-rpr-find-overlapping-scan (car bb) (cadr bb)))
        (cond
          (scan-tuple
           (setq scan-id (car scan-tuple)))
          (T
           (setq *DSLD-RPR-SCAN-COUNTER* (1+ *DSLD-RPR-SCAN-COUNTER*))
           (setq scan-id *DSLD-RPR-SCAN-COUNTER*)))
        (setq margin (* *DSLD-RPR-LABEL-HEIGHT* 6.0))
        (setq scan-tuple
              (dsld-rpr-register-scan
                scan-id
                (list (- (car  (car bb)) margin)
                      (- (cadr (car bb)) margin) 0.0)
                (list (+ (car  (cadr bb)) margin)
                      (+ (cadr (cadr bb)) margin) 0.0)
                *DSLD-RPR-LAST-OC*))
        (dsld-rpr-ensure-layer (nth 4 scan-tuple) roof-lay)
        (entmod (subst (cons 8 (nth 4 scan-tuple))
                       (assoc 8 (entget region))
                       (entget region)))
        (dsld-rpr-tag-pitch region pitch)
        (dsld-rpr-tint-poly region)
        ;; Regenerate the whole owning scan so rafters + H/R/V + chart
        ;; account for the new region.
        (dsld-rpr-refresh-scan scan-tuple)
        (princ (strcat "\n[RPRAREA] Added region at pitch "
                       (dsld-rpr-fmt-pitch pitch) "/12 (scan "
                       (itoa scan-id) ")."))))))
  (dsld-rpr-cleanup)
  (princ))

;;-----------------------------------------------------------------------;;
;; Auto-update from GitHub:  RPRUPDATE  (and load-time hook)
;;-----------------------------------------------------------------------;;
;; On file load, fetch the latest roof-pitch-rafters.lsp from the repo's
;; main branch.  If the bytes differ from the local file, back up the
;; current local file to .bak and overwrite it; tell the user to
;; restart the CAD so the new version actually runs.  Auto-run is
;; silent on "no internet" or "no change" so it never breaks load.
;;
;; HTTP via WinHttp.WinHttpRequest.5.1 (Windows-only -- if you need
;; macOS BricsCAD support later, replace the COM call with a shell-out
;; to curl).
;;-----------------------------------------------------------------------;;

;; GET <url>; return ResponseText on HTTP 200, nil otherwise.
;; SetTimeouts (resolve, connect, send, receive) caps the wait so we
;; never hang the file load on a slow / unreachable network.  Tight
;; timeouts (max 6 sec total) chosen so a dead network adds at most
;; that much to drawing-open time.
(defun dsld-rpr-fetch-remote-text (url / xml result)
  (setq result nil)
  ;; v1.8.0: vlax-invoke-METHOD (not plain vlax-invoke) -- AutoCAD's
  ;; plain vlax-invoke doesn't coerce the :vlax-false keyword for the
  ;; async parameter, so Open failed silently there.  The COM object is
  ;; also released OUTSIDE the catch now: the common no-internet case
  ;; threw at Send, skipping the release and leaking the object every
  ;; drawing-open.
  (vl-catch-all-apply
    '(lambda ()
       (setq xml (vlax-create-object "WinHttp.WinHttpRequest.5.1"))
       (vlax-invoke-method xml 'SetTimeouts 1500 1500 1500 6000)
       (vlax-invoke-method xml 'Open "GET" url :vlax-false)
       (vlax-invoke-method xml 'Send)
       (if (= 200 (vlax-get-property xml 'Status))
         (setq result (vlax-get-property xml 'ResponseText)))))
  (if xml (vl-catch-all-apply 'vlax-release-object (list xml)))
  result)

;; Slurp a local file into one string (read-line strips EOL so we add
;; "\n" back -- matches the LF-only line endings GitHub returns).
(defun dsld-rpr-read-local-file (path / f line content)
  (setq content "")
  (setq f (open path "r"))
  (cond
    (f
     (while (setq line (read-line f))
       (setq content (strcat content line "\n")))
     (close f)))
  content)

;; Write a string to a local file (overwrites).  Returns T on success.
(defun dsld-rpr-write-local-file (path content / f)
  (setq f (open path "w"))
  (cond
    (f
     (princ content f)
     (close f)
     T)))

;; Orchestrator.  verbose=T means print every branch (for c:RPRUPDATE);
;; verbose=nil means stay silent unless an update is applied (for the
;; load-time hook).
(defun dsld-rpr-update-if-needed (verbose / local-path remote local backup)
  (setq local-path (findfile "roof-pitch-rafters.lsp"))
  (cond
    ((not local-path)
     (if verbose (princ "\n[RPRUPDATE] Can't locate local file in support path."))
     nil)
    (T
     (setq remote (dsld-rpr-fetch-remote-text *DSLD-RPR-GITHUB-RAW-URL*))
     (cond
       ((not remote)
        (if verbose (princ "\n[RPRUPDATE] GitHub unreachable (using local copy)."))
        nil)
       (T
        (setq local (dsld-rpr-read-local-file local-path))
        (cond
          ((equal local remote)
           (if verbose
             (princ (strcat "\n[RPRUPDATE] Already up to date (v"
                            *DSLD-RPR-VERSION* ").")))
           nil)
          (T
           (setq backup (strcat local-path ".bak"))
           (if (findfile backup) (vl-file-delete backup))
           (vl-file-copy local-path backup)
           (cond
             ((dsld-rpr-write-local-file local-path remote)
              (princ "\n============================================================")
              (princ "\n[RPR] *** Auto-update: new version downloaded from GitHub.")
              (princ "\n[RPR] *** Backup saved as .bak.  Restart CAD to use it.")
              (princ "\n============================================================")
              T)
             (T
              (if verbose
                (princ "\n[RPRUPDATE] Could not write local file (permission?)."))
              nil)))))))))

(defun c:RPRUPDATE ( )
  (vl-load-com)
  (princ (strcat "\n[RPRUPDATE] Local v" *DSLD-RPR-VERSION*
                 ".  Checking GitHub..."))
  (dsld-rpr-update-if-needed T)
  (princ))

;;-----------------------------------------------------------------------;;
;; Field diagnostic:  RPRDIAG
;;-----------------------------------------------------------------------;;
;; One command a field user runs when RPR misbehaves on their machine;
;; they email us the report file.  Dumps environment, sysvars, layer
;; states, scan registry, entity counts, the last swallowed refresh
;; error, and LIVE-TESTS a hatch entmake using the exact DXF list the
;; real fills use.  Output goes to the text screen AND to
;; %TEMP%\rpr-diag.txt.
;;-----------------------------------------------------------------------;;

(defun dsld-rpr-diag-line (s)
  (princ (strcat "\n" s))
  (if *dsld-rpr-diag-file*
    (princ (strcat s "\n") *dsld-rpr-diag-file*)))

(defun dsld-rpr-diag-var (name / v)
  (setq v (vl-catch-all-apply 'getvar (list name)))
  (dsld-rpr-diag-line
    (strcat "  " name " = "
            (cond
              ((vl-catch-all-error-p v) "<unavailable>")
              ((not v) "nil")
              ((= (type v) 'STR)  v)
              ((= (type v) 'INT)  (itoa v))
              ((= (type v) 'REAL) (rtos v 2 4))
              (T "?")))))

(defun dsld-rpr-diag-count (etype lay / ss)
  (setq ss (ssget "_X" (list (cons 0 etype) (cons 8 lay))))
  (if ss (sslength ss) 0))

;; Layer state straight from the table record: negative color = OFF,
;; 70 bit 0 = frozen, bit 2 = locked.
(defun dsld-rpr-diag-layer (lay / rec clr f70)
  (setq rec (tblsearch "LAYER" lay))
  (cond
    ((not rec)
     (dsld-rpr-diag-line (strcat "  " lay " : MISSING")))
    (T
     (setq clr (cdr (assoc 62 rec)))
     (setq f70 (cdr (assoc 70 rec)))
     (dsld-rpr-diag-line
       (strcat "  " lay " : "
               (if (minusp clr) "OFF" "on")
               (if (= 1 (logand f70 1)) " FROZEN" "")
               (if (= 4 (logand f70 4)) " LOCKED" "")
               "  color " (itoa (abs clr)))))))

;; entmake a 1x1 SOLID hatch on the current layer via the SAME ladder
;; production fills use, then delete it.  Returns a verdict string
;; naming which list form the platform accepted.
(defun dsld-rpr-diag-hatch-test ( / e)
  (setq e (dsld-rpr-make-fill-hatch
            '((0.0 0.0) (1.0 0.0) (1.0 1.0) (0.0 1.0))
            (getvar "CLAYER") 1))
  (cond
    (e (entdel e)
       (strcat "OK -- accepted via '" *DSLD-RPR-HATCH-VARIANT* "' form"))
    (T "FAILED -- ALL THREE hatch list forms rejected (entmakex nil)")))

(defun c:RPRDIAG ( / path s lay-rec lay-name sid hs i hn hobj tr)
  (vl-load-com)
  (setq path (strcat (cond ((getenv "TEMP")) (".")) "\\rpr-diag.txt"))
  (setq *dsld-rpr-diag-file*
        (vl-catch-all-apply 'open (list path "w")))
  (if (vl-catch-all-error-p *dsld-rpr-diag-file*)
    (setq *dsld-rpr-diag-file* nil))

  (dsld-rpr-diag-line "=== RPR FIELD DIAGNOSTIC ===")
  (dsld-rpr-diag-line (strcat "RPR version : " *DSLD-RPR-VERSION*))
  (dsld-rpr-diag-var "ACADVER")
  (dsld-rpr-diag-var "PROGRAM")
  (dsld-rpr-diag-var "PRODUCT")
  (dsld-rpr-diag-line
    (strcat "Drawing     : " (getvar "DWGPREFIX") (getvar "DWGNAME")))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "-- sysvars --")
  (foreach s '("TRANSPARENCYDISPLAY" "FILLMODE" "DRAWORDERCTL"
               "PICKSTYLE" "PICKFIRST" "GRIPS" "HPGAPTOL" "OSMODE")
    (dsld-rpr-diag-var s))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "-- output layers --")
  (foreach s (list *DSLD-RPR-RAFTER-LAYER* *DSLD-RPR-LABEL-LAYER*
                   *DSLD-RPR-FILL-LAYER*   *DSLD-RPR-PITCH-LBL-LAYER*
                   *DSLD-RPR-OVERLAP-LAYER* *DSLD-RPR-CHART-LAYER*)
    (dsld-rpr-diag-layer s))
  ;; every RPR<N> scan layer in the table + its polygon count
  (setq lay-rec (tblnext "LAYER" T))
  (while lay-rec
    (setq lay-name (cdr (assoc 2 lay-rec)))
    (setq sid (dsld-rpr-scan-id-from-layer lay-name))
    (cond
      (sid
       (dsld-rpr-diag-layer lay-name)
       (dsld-rpr-diag-line
         (strcat "       polygons: "
                 (itoa (dsld-rpr-diag-count "LWPOLYLINE" lay-name))))))
    (setq lay-rec (tblnext "LAYER")))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "-- scan registry --")
  (if (not *DSLD-RPR-SCANS*) (dsld-rpr-rediscover-scans))
  (cond
    ((not *DSLD-RPR-SCANS*)
     (dsld-rpr-diag-line "  (empty -- no RPR<N> layers found either)"))
    (T
     (foreach s *DSLD-RPR-SCANS*
       (dsld-rpr-diag-line
         (strcat "  slot " (itoa (car s))
                 "  layer " (nth 4 s)
                 "  oc " (rtos (nth 3 s) 2 1)
                 "  polys-in-bbox "
                 (itoa (length (dsld-rpr-ents-in-bbox
                                 "LWPOLYLINE" (nth 4 s)
                                 (nth 1 s) (nth 2 s) 0.0))))))))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "-- entity counts (whole drawing) --")
  (dsld-rpr-diag-line
    (strcat "  rafter LINEs   : "
            (itoa (dsld-rpr-diag-count "LINE" *DSLD-RPR-RAFTER-LAYER*))))
  (dsld-rpr-diag-line
    (strcat "  label TEXTs    : "
            (itoa (dsld-rpr-diag-count "TEXT" *DSLD-RPR-LABEL-LAYER*))))
  (dsld-rpr-diag-line
    (strcat "  H/R/V CIRCLEs  : "
            (itoa (dsld-rpr-diag-count "CIRCLE" *DSLD-RPR-LABEL-LAYER*))))
  (dsld-rpr-diag-line
    (strcat "  fill HATCHes   : "
            (itoa (dsld-rpr-diag-count "HATCH" *DSLD-RPR-FILL-LAYER*))))
  (dsld-rpr-diag-line
    (strcat "  chart TEXTs    : "
            (itoa (dsld-rpr-diag-count "TEXT" *DSLD-RPR-CHART-LAYER*))))
  ;; transparency of the first few fills (90+ can read as invisible)
  (setq hs (ssget "_X" (list '(0 . "HATCH")
                             (cons 8 *DSLD-RPR-FILL-LAYER*))))
  (cond
    (hs
     (setq i 0)
     (while (and (< i (sslength hs)) (< i 5))
       (setq hn (ssname hs i))
       (setq tr (vl-catch-all-apply
                  '(lambda ()
                     (vla-get-EntityTransparency
                       (vlax-ename->vla-object hn)))))
       (dsld-rpr-diag-line
         (strcat "    hatch " (itoa i)
                 "  color " (itoa (cond ((cdr (assoc 62 (entget hn)))) (256)))
                 "  transparency "
                 (if (vl-catch-all-error-p tr) "<err>" (vl-princ-to-string tr))))
       (setq i (1+ i)))))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "-- live-edit reactor --")
  (dsld-rpr-diag-line
    (strcat "  installed : "
            (if (and *DSLD-RPR-WATCH-REACTOR*
                     (not (vl-catch-all-error-p
                            (vl-catch-all-apply
                              'vlr-added-p
                              (list *DSLD-RPR-WATCH-REACTOR*)))))
                "yes" "NO")))
  (dsld-rpr-diag-line
    (strcat "  weld snapshot polys : "
            (if *DSLD-RPR-VTX-CACHE*
              (itoa (length *DSLD-RPR-VTX-CACHE*))
              "0  <-- no snapshot: welding cannot run")))
  (dsld-rpr-diag-line
    (strcat "  reentry flag : "
            (if *DSLD-RPR-REFRESHING*
              "T  <-- STUCK, refreshes are being suppressed" "nil (ok)")))
  ;; The decisive datum for "I pulled a vertex and nothing happened":
  ;; did the edit reach the reactor at all, and under what name?
  (dsld-rpr-diag-line "  commands the reactor saw (newest first):")
  (cond
    ((not *DSLD-RPR-LAST-CMDS*)
     (dsld-rpr-diag-line
       "    (none -- no watched command has ended since the reactor armed)"))
    (T
     (foreach c *DSLD-RPR-LAST-CMDS*
       (dsld-rpr-diag-line (strcat "    " c)))))
  (dsld-rpr-diag-line
    (strcat "  last refresh error : "
            (cond (*DSLD-RPR-LAST-REFRESH-ERR*) ("none recorded"))))
  (dsld-rpr-diag-line
    (strcat "  fill entmake failures this session : "
            (itoa (cond (*DSLD-RPR-FILL-FAILS*) (0)))))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "-- live hatch entmake test --")
  (dsld-rpr-diag-line (strcat "  " (dsld-rpr-diag-hatch-test)))

  (dsld-rpr-diag-line "")
  (dsld-rpr-diag-line "=== END DIAGNOSTIC ===")
  (cond
    (*dsld-rpr-diag-file*
     (close *dsld-rpr-diag-file*)
     (setq *dsld-rpr-diag-file* nil)
     (princ (strcat "\n[RPRDIAG] Report saved to " path
                    " -- email that file."))))
  (textscr)
  (princ))

;; (The old alert-based RPRHELP was removed in v1.5.1.  RPRHELP is now
;;  an alias for c:RPRPANEL -- the workflow text and clickable
;;  command-button "live links" are baked into the same DCL dialog.
;;  See the RPRPANEL section above.)
;; (First-run auto-popup also removed -- user runs RPRPANEL or
;;  RPRHELP when they want the dialog.)

;; Auto-update on file load -- but ONCE per CAD session, not on every
;; drawing open.  *DSLD-RPR-UPDATE-CHECKED* is an unbound (nil) global
;; on the first load of the session; we flip it to T after the first
;; check so subsequent loads (when the user opens a new drawing or
;; switches dwg tabs) skip the GitHub round-trip entirely.  CAD
;; restart re-arms it.  Wrapped in vl-catch-all-apply so any network /
;; COM failure does not break the load.  Disable entirely by setting
;; *DSLD-RPR-AUTOUPDATE* to nil in your acaddoc.lsp.
(cond
  ((and *DSLD-RPR-AUTOUPDATE* (not *DSLD-RPR-UPDATE-CHECKED*))
   (vl-catch-all-apply 'dsld-rpr-update-if-needed (list nil))
   (setq *DSLD-RPR-UPDATE-CHECKED* T)))

;; v1.9.15: re-arm live-edit mode if this reload just tore down a live
;; reactor.  Without this, APPLOADing a new build silently turned live
;; edit OFF -- grip edits stopped regenerating rafters and left the
;; H/R/V callouts stranded at their old coordinates.
(cond
  (*DSLD-RPR-WATCH-WAS-ON*
   (vl-catch-all-apply 'dsld-rpr-ensure-watch)
   (setq *DSLD-RPR-WATCH-WAS-ON* nil)
   (if *DSLD-RPR-WATCH-REACTOR*
     (princ "\n[RPR] Live edit mode re-armed after reload."))))

(princ (strcat "\n[RPR] roof-pitch-rafters v" *DSLD-RPR-VERSION* " loaded."))
(princ "\n      RPRPANEL     = pop-up controller (workflow + button menu).")
(princ "\n      RPR          = bbox -> spacing -> render rafters + chart;")
(princ "\n                     loop for missed areas; live edit mode auto-on.")
(princ "\n      RPRREFRESH   = manually regenerate over a window.")
(princ "\n      RPRMISS      = capture an area the scan missed (any time).")
(princ "\n      RPRAREA      = bridge an open area (back porch, shed, etc.).")
(princ "\n      RPRDRAW      = outline + add a region by hand.")
(princ "\n      RPRADD       = add a single rafter.")
(princ "\n      RPRFIX       = override one region's pitch / direction.")
(princ "\n      RPRCALCPITCH = label loose LINEs on a given pitch.")
(princ "\n      RPRRESULT    = hide design layers (rafters + chart only).")
(princ "\n      RPRSHOW      = show every SSS layer back on.")
(princ "\n      RPREDIT      = unlock group select (AutoCAD grip edits).")
(princ "\n      RPRGROUP     = re-lock click-selects-both.")
(princ "\n      RPRUNWATCH   = turn off live edit mode.")
(princ "\n      RPRUPDATE    = fetch latest version from GitHub.")
(princ "\n      RPRDIAG      = write a diagnostic report (send when reporting bugs).")
(princ "\n      RPRHELP      = same as RPRPANEL.")
(princ)
