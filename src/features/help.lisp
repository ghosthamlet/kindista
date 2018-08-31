;;; Copyright 2012-2016 CommonGoods Network, Inc.
;;;
;;; This file is part of Kindista.
;;;
;;; Kindista is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU Affero General Public License as published
;;; by the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; Kindista is distributed in the hope that it will be useful, but WITHOUT
;;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;;; License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public License
;;; along with Kindista.  If not, see <http://www.gnu.org/licenses/>.

(in-package :kindista)

(defun new-feedback-notice-handler ()
  (send-feedback-notification-email (getf (cddddr *notice*) :id)))

(defun new-feedback-reply-notice-handler ()
  (send-feedback-reply-notification-email (getf (cddddr *notice*) :id)))

(defun create-feedback (&key (by *userid*) text (time (get-universal-time)))
  (let ((id (insert-db (list :type :feedback
                             :text text
                             :by by
                             :created time))))

    (notice :new-feedback :time time :id id)
    id))

(defun index-feedback (id data)
  (let* ((by (getf data :by))
         (created (getf data :created))
         (result (make-result :people (list by)
                              :time created
                              :type :feedback
                              :id id)))

    (with-mutex (*feedback-mutex*)
      (setf *feedback-index* (safe-sort (cons result *feedback-index*)
                                        #'> :key #'result-time)))

    (with-locked-hash-table (*db-results*)
      (setf (gethash id *db-results*) result))))

(defun delete-feedback (id)
  (let ((result (gethash id *db-results*)))

    (delete-comments id)

    (with-locked-hash-table (*db-results*)
      (remhash id *db-results*))

    (with-mutex (*feedback-mutex*)
      (asetf *feedback-index* (remove result it)))

    (remove-from-db id)))

(defun help-tabs-html (&key tab)
  (html
    (str
      (menu-horiz
        (html
          (if *userid*
            (htm (:a :href "/contact-us" "contact us"))
            (htm (:a :href "mailto:info@kindista.org" "contact us"))))  
        (html (:a :href (strcat "/groups/" (username-or-id +kindista-id+) "/reputation") "express gratitude for " (str (db +kindista-id+ :name))))))
    (:menu :class "bar"
      (if (eql tab :faq)
   (htm (:li :class "selected" "Frequent Questions"))
   (htm (:li (:a :href "/faq" "Frequent Questions"))))
      (when *user*
        (if (eql tab :feedback)
            (htm (:li :class "selected" "Feedback"))
            (htm (:li (:a :href "/feedback" "Feedback")))))
             (if (eql tab :about)
          (htm (:li :class "selected" "About Kindista"))
          (htm (:li (:a :href "/about" "About Kindista")))))))

(defun go-help ()
  (see-other "/feedback"))

(defparameter *faq-html* (markdown-file (s+ +markdown-path+ "faq.md")))

(defun get-faq ()
  (standard-page
    "Frequently Asked Questions"
    (html
      (str (help-tabs-html :tab :faq))
      (:div :class "legal faq"
        (str *faq-html*)))
    :selected "faq"
    :right (html
             (str (donate-sidebar))
             (str (invite-sidebar)))))

(defun get-feedbacks ()
  (if *user*
    (standard-page
      "Feedback"
      (html
        (str (help-tabs-html :tab :feedback))
        (:div :class "item"
         (:h4 "Ask a question, report a problem, or suggest a new feature:")
         (:form :method "post" :action "/feedback"
           (:table :class "post"
            (:tr
              (:td (:textarea :cols "1000" :rows "4" :name "text"))
              (:td
                (:button :class "yes" :type "submit" :class "submit" :name "create" "Post")))))) 

         (dolist (result *feedback-index*)
           (str (feedback-card (result-id result)))))
      :selected "faq"
      :right (html
               (str (donate-sidebar))
               (str (invite-sidebar))))
    (see-other "/faq")))

(defun post-feedbacks ()
  (require-user ()
    (let ((text (post-parameter "text")))
      (cond
        ((and text (not (string= text "")))
         (create-feedback :text text))
        (t
         (flash "Please provide some text for your feedback." :error t))))
    (see-other "/feedback")))

(defun get-feedback (id)
  (require-user ()
    (let* ((id (parse-integer id))
           (data (db id)))
      (if (eq (getf data :type) :feedback)
        (standard-page
          "Feedback"
          (html
            (str (feedback-card id))))
        (not-found)))))

(defun post-feedback (id)
  (require-user ()
    (let* ((id (parse-integer id))
           (data (db id)))
      (if (eq (getf data :type) :feedback)
        (cond
          ((post-parameter "delete")
           (confirm-delete :url (script-name*)
                           :type "feedback"
                           :text (getf data :text)
                           :next-url (referer)))
          ((post-parameter "really-delete")
           (delete-feedback id)
           (flash "Your feedback has been deleted!")
           (see-other (or (post-parameter "next") "/feedback")))
          ((and (post-parameter "text")
                (getf *user* :admin))
           (notice :new-feedback-reply
                   :id (create-comment :on id
                                       :text (post-parameter "text")))
           (see-other "/feedback"))
          (t
           (flash "WTF?" :error t)
           (see-other "/feedback")))))))

(defun go-contact-us ()
  (require-user ()
    (new-conversation :people (list +kindista-id+)
                      :single-recipient "t"
                      :next (or (referer) "/home"))))

