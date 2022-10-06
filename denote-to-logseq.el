;;; notes-migrator.el --- Migrate notes from org-roam to denote

;; Copyright (C) 2022 bitspook <bitspook@proton.me>

;; Author: bitspook <bitspook@proton.me>
;; Version: 0.1
;; URL: https://github.com/bitspook/notes-migrator

;;; Commentary:
;; Migrate org-roam notes to denote. It does not make any changes to org-roam
;; notes, but migrated-notes are saved in denote-directory while overwriting any
;; conflicting files.

;;; Code:

(require 'denote)
(require 'org-element)

(defun nm--roam-node-ctime (node)
  "Get create-time of org-roam NODE.
It assumes that date is stored in the filename of NODE in one of
the 3 formats:
- YYYY-MM-DD.org (e.g in case of org-roam-dailies)
- YYYYMMDDHHMMSS.*.org (new org-roam nodes)
- YYYY-MM-DD--HH-MM-SS.*.org (old org-roam nodes)"
  (let* ((fname (file-name-base (org-roam-node-file node)))
         (old-date-rx (rx (group (= 4 num) "-" (= 2 num) "-" (= 2 num))
                          "--" (group (= 2 num)) "-" (group (= 2 num)) "-" (group (= 2 num)) "Z"))
         (new-date-rx (rx (group (= 4 num)) (group (= 2 num)) (group (= 2 num))
                          (group (= 2 num)) (group (= 2 num)) (group (= 2 num)) "-"))
         (dailies-date-rx (rx (= 4 num) "-" (= 2 num) "-" (= 2 num)))
         (time-str (save-match-data
                     (or (and (string-match old-date-rx fname)
                              (concat (match-string 1 fname) "T"
                                      (format "%s:%s:%s" (match-string 2 fname) (match-string 3 fname) (match-string 4 fname))))
                         (and (string-match new-date-rx fname)
                              (format "%s-%s-%sT%s:%s:%s"
                                      (match-string 1 fname) (match-string 2 fname) (match-string 3 fname)
                                      (match-string 4 fname) (match-string 5 fname) (match-string 6 fname)))
                         (and (string-match dailies-date-rx fname)
                              (format "%sT00:00:00" (match-string 0 fname)))))))
    (when (not time-str) (error "Encountered org-roam file with unknown name: %s.org" fname))
    (encode-time (parse-time-string time-str))))

(defun nm--roam-node-denote-id (node)
  "Create denote identifier for org-roam NODE.
It returns creation timestamp of NODE, which is obtained using `nm--roam-node-ctime'."
  (format-time-string denote--id-format (nm--roam-node-ctime node)))

(defun nm--roam-node-denote-filename (node)
  "Return valid denote file name for org-roam NODE."
  (let* ((id (nm--roam-node-denote-id node))
         (tags (mapcar #'downcase (org-roam-node-tags node)))
         (title (or (string-replace "/" "-" (org-roam-node-title node)) "untitled")))
    (concat id "--" (denote-sluggify title) "__" (string-join tags "_") ".org")))

(defun nm--org-element-save-to-buffer (el)
  "Save `org-element' EL back in `current-buffer'.
Make sure EL is obtained from `current-buffer.'"
  (let ((begin (org-element-property :begin el))
        (end (org-element-property :end el)))
    (delete-region begin end)
    (goto-char begin)
    (insert (org-element-interpret-data el))))

(defun nm--convert-roam-links-to-denote (&optional filename)
  "Convert all org-roam links in `current-buffer' to denote links.
If org-roam node for a link is not found, a warning is logged and
the link is not converted.
FILENAME can be optionally provided for debugging in case of
failed link conversions."
  (let ((roam-link-rx (rx "[[id:")))
    (while (re-search-forward roam-link-rx nil t)
      (let* ((el (org-element-copy (org-element-context)))
             (node-id (org-element-property :path el))
             (node (org-roam-node-from-id node-id)))
        (if (not node)
            (warn "Failed to convert org-roam link to denote because corresponding org-roam node wasn't found. [id=%s, filename=%s]" node-id filename)

          (let* ((begin (org-element-property :begin el))
                 (end (org-element-property :end el))
                 (s (buffer-substring begin end)))
            (replace-string (format "id:%s" node-id) (format "denote:%s" (nm--roam-node-denote-id node))
                            nil begin end)))))))

(defun nm--convert-denote-links-to-logseq (filename)
  (let ((denote-link-rx (rx (and (group "[[denote:" (= 8 num))
				 (group	"T" (= 6 num))
				 (group "][" (* (or ascii nonascii)))
				 (group	"]]")))))
    (while (re-search-forward denote-link-rx nil t)
      (let* (())))
    )

  )

(defun test-fn (in-file out-file)
  (with-temp-buffer
    (erase-buffer)
    (insert (org-file-contents in-file))

    (delete-file out-file)
    (write-file out-file nil)))


(defun nm--add-org-file-tags (tags)
  "Set #+filetags in `current-buffer' to TAGS.
Existing filetags aren't removed, but are converted to :tag:
format."
  (goto-char (point-min))
  (re-search-forward (rx "#+title: ") nil t)
  (end-of-line)

  (when (not (re-search-forward (rx "#+filetags: ") nil t))
    (insert "\n#+filetags: "))

  (let* ((el (org-element-context))
         (old-tags (org-element-property :value el)))
    (setf old-tags (split-string (string-replace " " ":" old-tags) ":" t))
    (org-element-put-property el :value (concat ":" (string-join (seq-concatenate 'list old-tags tags) ":") ":"))
    (nm--org-element-save-to-buffer el)))

(defun nm--migrate-roam-node (node &optional extra-tags)
  "Convert org-roam NODE to delink note.
If EXTRA-TAGS is provided, also add these to delink note's tags.
Behavior:
- Creates a new file in `denote-directory'.
- If file with the name already exists, it is overwritten.
- If the notes was previous exported but sees a change in title
  or tags, a new file is created in `denote-directory'"
  (let ((file (org-roam-node-file node))
        (new-name (expand-file-name (nm--roam-node-denote-filename node)
                                    denote-directory))
        (count 0))
    (with-temp-buffer
      (erase-buffer)
      (insert (org-file-contents file))
      (goto-char (point-min))
      ;; Delete the properties drawer roam inserts on top
      (dotimes (_ 3) (delete-line))
      (org-mode)
      (nm--convert-roam-links-to-denote new-name)

      (when extra-tags
        (setf new-name
              (string-replace
               ".org" (concat (string-join extra-tags "_") ".org") new-name))
        (nm--add-org-file-tags extra-tags))

      (delete-file new-name)
      (write-file new-name nil))))

;;;###autoload
(defun migrate-org-roam-to-denote (dailies-tag)
  "Migrate all org-roam notes to denote.
Denote notes are saved as new files in `denote-directory'. denote
must be loaded and configured beforehand. DAILIES-TAG is added to
org-roam-dailies entries. If it is an empty string, dailies are
not migrated."
  (interactive "sTag for the dailies (leave empty to not migrate org-roam-dailies): ")
  (let* ((roam-nodes (org-roam-node-list))
         (notes (cl-remove-if (lambda (node) (s-contains-p "daily" (org-roam-node-file node))) roam-nodes))
         (dailies (cl-remove-if-not (lambda (node) (s-contains-p "daily" (org-roam-node-file node))) roam-nodes)))
    (mapcar #'nm--migrate-roam-node notes)

    (when (not (string-empty-p (string-trim dailies-tag)))
      (mapcar (lambda (n) (nm--migrate-roam-node n (list dailies-tag))) dailies))))

(provide 'notes-migrator)
;;; notes-migrator.el ends here