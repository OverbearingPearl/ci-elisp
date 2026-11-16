;;; 18-adr-format.el --- decision records keep one shape -*- lexical-binding: t; -*-

;;; Commentary:

;; A decision log is only checkable while every record has the same shape: a
;; number in the file name that matches the number in the title, a status
;; drawn from a closed vocabulary, and the sections that carry the argument.
;; Without this, a record can claim to be accepted while its status line says
;; otherwise, and the log becomes a place where a decision is described
;; rather than settled.
;;
;; Two styles are accepted, because both are in the wild and both are
;; readable.  Nygard's short form is a title, a Date line, Status and the
;; three sections.  MADR is the same argument with YAML front matter and a
;; decision-outcome heading.  A file is asked to be one of them rather than a
;; mixture, and the sections are matched case-insensitively so a project may
;; capitalise headings its own way.

;;; Code:

(defconst p/adr-name-rx
  (rx bos (group (= 4 digit)) "-" (+ (not ?/)) ".md" eos)
  "Regexp matching an ADR file name, capturing its number.")

(defconst p/adr-statuses
  '("proposed" "accepted" "rejected" "deprecated" "superseded" "amended")
  "Every status an ADR may start with, lower-cased.")

(defconst p/adr-toc-name "decisions.md"
  "The generated table of contents, which is not itself a record.")

(defun p/adr-dir ()
  "Return the absolute decision directory, or nil."
  (let ((rel (p/config-value :adr-dir)))
    (when rel
      (let ((dir (expand-file-name rel (p/repo-root))))
        (and (file-directory-p dir) dir)))))

(defun p/adr-files ()
  "Return (FILE . PLACE) for every record under the decision directory.
PLACE is `top' or `superseded'."
  (let ((dir (p/adr-dir)))
    (when dir
      (append
       (mapcar (lambda (f) (cons f 'top))
               (p/dir-md-files dir))
       (mapcar (lambda (f) (cons f 'superseded))
               (p/dir-md-files (expand-file-name "superseded" dir)))))))

(defun p/dir-md-files (dir)
  "Return the Markdown files directly inside DIR, sorted."
  (when (file-directory-p dir)
    (sort (seq-filter (lambda (f) (and (file-regular-p f)
                                       (string-suffix-p ".md" f)))
                      (directory-files dir t))
          #'string<)))

(defun p/adr-line-text (file)
  "Return the lines of FILE as a list of strings."
  (p/file-lines file))

(defun p/adr-front-matter-end (lines)
  "Return the index of the line closing front matter in LINES, or nil.
Front matter starts on the first line with `---'.  Index 0 is the opener."
  (when (and lines (string= "---" (string-trim (car lines))))
    (let ((index 1)
          (found nil))
      (while (and lines (not found))
        (when (and (< index (length lines))
                   (string= "---" (string-trim (nth index lines))))
          (setq found index))
        (setq index (1+ index)))
      found)))

(defun p/adr-madr-p (lines)
  "Return non-nil when LINES open with YAML front matter."
  (and (p/adr-front-matter-end lines) t))

(defun p/adr-heading-text (line)
  "Return LINE without its leading hashes and blanks."
  (let ((start (string-match "[^# \t]" line)))
    (if start (string-trim (substring line start)) "")))

(defun p/adr-blank-line-p (line)
  "Return non-nil when LINE holds only blanks."
  (string-empty-p (string-trim (or line ""))))

(defun p/adr-status-line (lines)
  "Return (STATUS . LINE-NUMBER) from the `## Status' section of LINES.
Blank lines between the heading and the value are skipped, so the usual
`## Status' followed by an empty line and then the value reads correctly."
  (let ((index 0)
        (found nil))
    (while (and lines (not found))
      (when (let ((case-fold-search t))
              (string-match-p (rx line-start "##" (+ blank) "status" (* blank)
                                  line-end)
                              (nth index lines)))
        (let ((next (1+ index)))
          (while (and (< next (length lines))
                      (p/adr-blank-line-p (nth next lines)))
            (setq next (1+ next)))
          (setq found (cons (and (< next (length lines))
                                 (not (string-prefix-p "#" (nth next lines)))
                                 (string-trim (nth next lines)))
                            (1+ next)))))
      (setq index (1+ index)))
    found))

(defun p/adr-heading-p (text name)
  "Return non-nil when heading TEXT names NAME, ignoring case."
  (string= (downcase (string-trim text)) (downcase name)))

(defun p/adr-has-section-p (lines names)
  "Return non-nil when LINES has a level-two heading among NAMES."
  (let ((found nil))
    (dolist (line lines)
      (when (and (not found)
                 (string-match-p (rx line-start "##" (+ blank)) line))
        (let ((text (p/adr-heading-text line)))
          (when (seq-find (lambda (name) (p/adr-heading-p text name)) names)
            (setq found t)))))
    found))

(defun p/adr-check-title (check file lines number)
  "Report a title in FILE that does not match NUMBER."
  (let ((title (seq-find (lambda (line)
                           (string-match-p (rx line-start "#" blank) line))
                         lines)))
    (cond
     ((null title)
      (p/add-error check file nil "record has no `# title' heading"))
     ((string-match (rx line-start "#" (+ blank) (group (+ digit)) "." (+ blank))
                    title)
      (unless (= (string-to-number number)
                 (string-to-number (match-string 1 title)))
        (p/add-error check file nil
                     (format "title says %s but the file name says %s"
                             (match-string 1 title) number)))))))

(defun p/adr-check-headings (check file lines madr)
  "Report missing sections in FILE, given LINES and MADR style."
  (let ((required (if madr
                      '(("context" "context and problem statement")
                        ("decision outcome" "decision")
                        ("consequences"))
                    '(("context") ("decision") ("consequences")))))
    (dolist (group required)
      (unless (p/adr-has-section-p lines group)
        (p/add-error check file nil
                     (format "missing a `## %s' section"
                             (capitalize (car group))))))))

(defun p/adr-check-date (check file lines)
  "Report a Nygard record in FILE without a `Date:' line."
  (unless (seq-find (lambda (line)
                      (string-match-p
                       (rx line-start "date:" (+ blank)
                           (= 4 digit) "-" (= 2 digit) "-" (= 2 digit))
                       (downcase line)))
                    lines)
    (p/add-error check file nil
                 "Nygard style needs a `Date: YYYY-MM-DD' line")))

(defun p/adr-check-status (check file lines place)
  "Report a status in FILE that is unknown or contradicts PLACE."
  (let ((status (p/adr-status-line lines)))
    (cond
     ((null status)
      (p/add-error check file nil "missing a `## Status' section"))
     ((string-empty-p (car status))
      (p/add-error check file (cdr status) "`## Status' has no value"))
     (t
      (let ((word (downcase (car (split-string (car status) "[^a-zA-Z]+" t)))))
        (cond
         ((not (member word p/adr-statuses))
          (p/add-error check file (cdr status)
                       (format "status `%s' is not one of %s"
                               word (string-join p/adr-statuses ", "))))
         ((and (eq place 'superseded)
               (not (member word '("superseded" "amended"))))
          (p/add-error check file (cdr status)
                       "a record moved to superseded/ must say so in its status"))
         ((and (eq place 'top) (string= word "superseded"))
          (p/add-error check file (cdr status)
                       "a superseded record belongs in superseded/"))))))))

(defun p/adr-check-file (check root file place)
  "Check one record: FILE under ROOT, living at PLACE."
  (let* ((name (file-name-nondirectory file))
         (lines (p/adr-line-text file))
         (madr (p/adr-madr-p lines)))
    (if (or (string= name p/adr-toc-name)
            (string-prefix-p "0000-" name))
        nil
      (if (not (string-match p/adr-name-rx name))
          (p/add-error check file nil
                       "a record is named NNNN-kebab-title.md")
        (let ((number (match-string 1 name)))
          (p/adr-check-title check file lines number)
          (p/adr-check-status check file lines place)
          (p/adr-check-headings check file lines madr)
          (unless madr
            (p/adr-check-date check file lines)))))))

(p/defcheck-global adr-format :scope "Markdown: the decision directory"
  "Every decision record has a number, a status and the argued sections."
  (let* ((dir (p/adr-dir))
         (root (p/repo-root))
         (entries (p/adr-files)))
    (when dir
      (dolist (entry entries)
        (p/adr-check-file check root (car entry) (cdr entry)))
      ;; Two records may not share a number, because the number is the
      ;; reference a later record uses when it supersedes one.
      (let ((seen (make-hash-table :test #'equal)))
        (dolist (entry entries)
          (let* ((name (file-name-nondirectory (car entry)))
                 (number (and (string-match p/adr-name-rx name)
                              (match-string 1 name))))
            (when number
              (if (gethash number seen)
                  (p/add-error check (car entry) nil
                               (format "number %s is already used by %s"
                                       number (gethash number seen)))
                (puthash number (file-relative-name (car entry) root) seen)))))))))
