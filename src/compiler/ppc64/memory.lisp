;;;; the PPC definitions of some general purpose memory reference VOPs
;;;; inherited by basic memory reference operations

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;;; Cell-Ref and Cell-Set are used to define VOPs like CAR, where the offset to
;;; be read or written is a property of the VOP used.
;;;
(define-vop (cell-ref)
  (:args (object :scs (descriptor-reg)))
  (:results (value :scs (descriptor-reg any-reg)))
  (:variant-vars offset lowtag)
  (:policy :fast-safe)
  (:generator 4
    (loadw value object offset lowtag)))
;;;
(define-vop (cell-set)
  (:args (object :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:variant-vars offset lowtag)
  (:policy :fast-safe)
  (:generator 4
    (storew value object offset lowtag)))

;;;; Indexed references:

;;; Define some VOPs for indexed memory reference.
(defmacro define-indexer (name write-p ri-op rr-op shift &optional sign-extend-byte)
  `(define-vop (,name)
     (:args (object :scs (descriptor-reg))
            (index :scs (any-reg zero immediate))
            ,@(when write-p
                '((value :scs (any-reg descriptor-reg) :target result))))
     (:arg-types * tagged-num ,@(when write-p '(*)))
     (:temporary (:scs (non-descriptor-reg)) temp)
     (:results (,(if write-p 'result 'value)
                :scs (any-reg descriptor-reg)))
     (:result-types *)
     (:variant-vars offset lowtag)
     (:policy :fast-safe)
     (:generator 5
       (sc-case index
         ((immediate zero)
          (let ((offset (- (+ (if (sc-is index zero)
                                  0
                                  (ash (tn-value index)
                                       (- word-shift ,shift)))
                              (ash offset word-shift))
                           lowtag)))
            (if (and (typep offset '(signed-byte 16))
                     (or (> ,shift 0) ;; If it's not word-index
                         (not (logtest offset #b11)))) ;; Or the displacement is a multiple of 4
                (inst ,ri-op value object offset)
                (progn
                  (inst lr temp offset)
                  (inst ,rr-op value object temp)))))
         (t
          ,@(unless (zerop shift)
              `((inst srdi temp index ,shift)))
          (inst addi temp ,(if (zerop shift) 'index 'temp)
                (- (ash offset word-shift) lowtag))
          (inst ,rr-op value object temp)))
       ,@(when sign-extend-byte
           `((inst extsb value value)))
       ,@(when write-p
           '((move result value))))))

(define-indexer word-index-ref nil ld ldx 0) ;; Word means Lisp Word
(define-indexer word-index-set t std stdx 0)
(define-indexer 32-bits-index-ref nil lwz lwzx 1)
(define-indexer 32-bits-index-set t stw stwx 1)
(define-indexer 16-bits-index-ref nil lhz lhzx 2)
(define-indexer signed-16-bits-index-ref nil lha lhax 2)
(define-indexer 16-bits-index-set t sth sthx 2)
(define-indexer byte-index-ref nil lbz lbzx 3)
(define-indexer signed-byte-index-ref nil lbz lbzx 3 t)
(define-indexer byte-index-set t stb stbx 3)

(define-vop (word-index-cas)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg zero immediate))
         (old-value :scs (any-reg descriptor-reg))
         (new-value :scs (any-reg descriptor-reg)))
  (:arg-types * tagged-num * *)
  (:temporary (:sc non-descriptor-reg) temp)
  (:results (result :scs (any-reg descriptor-reg) :from :load))
  (:result-types *)
  (:variant-vars offset lowtag)
  (:policy :fast-safe)
  (:generator 5
    (sc-case index
      ((immediate zero)
       (let ((offset (- (+ (if (sc-is index zero)
                               0
                             (ash (tn-value index) word-shift))
                           (ash offset word-shift))
                        lowtag)))
         (inst lr temp offset)))
      (t
       ;; KLUDGE: This relies on N-FIXNUM-TAG-BITS being the same as
       ;; WORD-SHIFT.  I know better than to do this.  --AB, 2010-Jun-16
       (inst addi temp index
             (- (ash offset word-shift) lowtag))))

    (inst sync)
    LOOP
    (inst lwarx result temp object)
    (inst cmpw result old-value)
    (inst bne EXIT)
    (inst stwcx. new-value temp object)
    (inst bne LOOP)
    EXIT
    (inst isync)))
