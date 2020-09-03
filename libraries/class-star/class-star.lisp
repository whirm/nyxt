;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :class*)

(defun name-identity (name definition)
  (declare (ignore definition))
  name)

(defun initform (definition)
  "Return (BOOLEAN INITFORM) when initform is found."
  (let ((definition (rest definition)))
    (if (oddp (length definition))
        (values t (first definition))
        (multiple-value-bind (found? value)
            (get-properties definition '(:initform))
          (values (not (null found?)) value)))))

(defun definition-type (definition)
  "Return definition's TYPE.
Return nil if not found."
  (let ((definition (rest definition)))
    (when (oddp (length definition))
      (setf definition (rest definition)))
    (getf definition :type)))

(defun basic-type-zero-values (type)
  "Return TYPE zero value as (ZERO-VALUE BOOLEAN).
BOOLEAN is non-nil if value was inferred, nil otherwise."
  (let* ((inferred? t)
         (zero-value (cond
                       ((subtypep type 'string) "")
                       ((subtypep type 'boolean) nil)
                       ((subtypep type 'list) '())
                       ((subtypep type 'array) (make-array 0))
                       ((subtypep type 'hash-table) (make-hash-table))
                       ;; Order matters for numbers:
                       ((subtypep type 'float) 0.0)
                       ((subtypep type 'number) 0) ; Includes complex numbers and rationals.
                       (t (setf inferred? nil)
                          nil))))
    (values (and inferred? zero-value) inferred?)))

(defun basic-type-inference (definition)
  "Return general type of VALUE.
This is like `type-of' but returns less specialized types for some common
subtypes, e.g.  for \"\" return 'string instead of `(SIMPLE-ARRAY CHARACTER
\(0))'.

Note that in a slot definition, '() is infered to be a list while NIL is infered
to be a boolean.

Non-basic form types are not infered (returns nil).
Non-basic scalar types are derived to their own type (with `type-of')."
  (multiple-value-bind (found? value)
      (initform definition)
    (when found?
      (cond
        ((and (consp value)
              (eq (first value) 'quote)
              (symbolp (second value)))
         (if (eq (type-of (second value)) 'null)
             'list                      ; The empty list.
             'symbol))
        ((and (consp value)
              (eq (first value) 'function))
         'function)
        ((and (consp value)
              (not (eq (first value) 'quote)))
         ;; Non-basic form.
         nil)
        (t (let* ((type (if (symbolp value)
                            (handler-case
                                ;; We can get type of externally defined symbol.
                                (type-of (eval value))
                              (error ()
                                ;; Don't infer type if symbol is not yet defined.
                                nil))
                            (type-of value))))
             (if type
                 (flet ((derive-type (general-type)
                          (when (subtypep type general-type)
                            general-type)))
                   (or (some #'derive-type '(string boolean list array hash-table integer
                                             complex number))
                       ;; Only allow objects of the same type by default.
                       ;; We could have returned nil to inhibit the generation of a
                       ;; :type property.
                       type))
                 nil)))))))

(defun type-zero-initform-inference (definition)
  "Infer basic type zero values.
See `basic-type-zero-values'.
Raise a condition at macro-expansion time when initform is missing for
unsupported types."
  (let ((type (definition-type definition)))
    (if type
        (multiple-value-bind (value found?)
            (basic-type-zero-values type)
          (if found?
              value
              ;; Compile-time error:
              (error "Missing initform.")))
        ;; Default initform when type is missing:
        nil)))

(defun no-unbound-initform-inference (definition)
  "Infer basic type zero values.
Raise a condition when instantiating if initform is missing for unsupported
types."
  (let ((type (definition-type definition)))
    (if type
        (multiple-value-bind (value found?)
            (basic-type-zero-values type)
          (if found?
              value
              ;; Run-time error:
              '(error "Slot must be bound.")))
        ;; Default initform when type is missing:
        nil)))

(defun nil-fallback-initform-inference (definition)
  "Infer basic type zero values.
Fall back to nil if initform is missing for unsupported types."
  (let ((type (definition-type definition)))
    (if type
        (multiple-value-bind (value found?)
            (basic-type-zero-values type)
          (if found?
              value
              ;; Fall-back to nil:
              nil))
        ;; Default initform when type is missing:
        nil)))

(defvar *initform-inference* 'type-zero-initform-inference
  "Fallback initform inference function.
Set this to nil to disable inference.")
(defvar *type-inference* 'basic-type-inference
  "Fallback type inference function.
Set this to nil to disable inference.")

(defun process-slot-initform (definition &key ; See `hu.dwim.defclass-star:process-slot-definition'.
                                           initform-inference
                                           type-inference)
  (unless (consp definition)
    (setf definition (list definition)))
  (cond
    ((and (initform definition)
          (or (definition-type definition)
              (not type-inference)))
     definition)
    ((and (initform definition)
          (not (definition-type definition))
          type-inference)
     (append definition
             (let ((result-type (funcall type-inference definition)))
               (when result-type
                 (list :type result-type)))))
    ((and (not (initform definition))
          initform-inference)
     (append definition
             (list :initform (funcall initform-inference definition))))
    ((and (not (initform definition))
          (not initform-inference))
     definition)
    (t (error "Condition fell through!"))))

(defmacro define-class (name supers &body (slots . options))
  "Define class like `defclass*' but with extensions.

The default initforms can be automatically inferred by the function specified
in the `:initform-inference' option, which defaults to `*initform-inference*'.
The initform can still be specified manually with `:initform' or as second
argument, right after the slot name.

The same applies to the types with the `:type-inference' option, the
`*type-inference*' default and the `:type' argument respectively."
  (let* ((initform-option (assoc :initform-inference options))
         (initform-inference (or (when initform-option
                                   (setf options (delete :initform-inference options :key #'car))
                                   (eval (second initform-option)))
                                 *initform-inference*))
         (type-option (assoc :type-inference options))
         (type-inference (or (when type-option
                               (setf options (delete :type-inference options :key #'car))
                               (eval (second type-option)))
                             *type-inference*)))
    `(hu.dwim.defclass-star:defclass* ,name ,supers
       ,(mapcar (lambda (definition)
                  (process-slot-initform
                   definition
                   :initform-inference initform-inference
                   :type-inference type-inference))
                slots)
       ,@options)))