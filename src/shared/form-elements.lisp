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

(defparameter *or-divider*
  (html
    (:div :class "or-divider"
     (:span "OR")
     (:hr))))

(defun number-selection-html (name end &key id selected auto-submit)
  (html
    (:select :name name
             :id id
             :onchange (when auto-submit "this.form.submit()")
      (loop for num from 1 to end
            do (htm
                 (:option :value (strcat num)
                          :selected (when (eql selected num) "")
                          (str (strcat num))))))))

(defun distance-selection-dropdown
  (distance
   &key auto-submit
        (everywhere-option t))
  (html
    (:select :class "distance-selection"
             :name "distance"
             :id "distance-selection"
             :onchange (when auto-submit "this.form.submit()")
      (:option :value "2" :selected (when (eql distance 2) "") "2 miles")
      (:option :value "5" :selected (when (eql distance 5) "") "5 miles")
      (:option :value "10" :selected (when (eql distance 10) "") "10 miles")
      (:option :value "25" :selected (when (eql distance 25) "") "25 miles")
      (:option :value "100" :selected (when (eql distance 100) "") "100 miles")
      (when everywhere-option
        (htm (:option :value "0" :selected (when (eql distance 0) "") "everywhere"))))))

(defun group-category-selection (&key next selected (class "identity"))
  (let* ((default-options '("business"
                            "church/spiritual community"
                            "community organization"
                            "government agency"
                            "intentional community"
                            "nonprofit organization"
                            "school/educational organization"))
         (custom (unless (member selected
                                 (cons "other" default-options)
                                 :test #'equalp)
                   selected)))
    (html
      (:div :class "form-elements"
        (awhen next (htm (:input :type "hidden" :name "next" :value it)))
        (:select :name "group-category"
                 :class (s+ "group-category-selection " class)
                 :onchange "this.form.submit()"
           (unless selected
             (htm (:option :value ""
                           :style "display:none;"
                           :selected "selected"
                     "Please select ...")))
           (dolist (option default-options)
             (htm (:option :value option
                           :selected (when (string= selected option) "")
                           (str (string-capitalize option)))))
           (:option :value "other"
                    :selected (when (or (string= selected "other")
                                        custom)
                                "")
                    "Other ..."))

        (when (or (string= selected "other") custom)
          (htm
            (:br)
            (:input :type "text"
                    :class "group-category-selection float-left"
                    :name "custom-group-category"
                    :placeholder "Please specify..."
                    :value (awhen custom (escape-for-html it)))))

        (:input :type "submit" :class "no-js" :value "apply")))))

(defun group-membership-method-selection (current &key auto-submit)
  (html
    (:h3 :class "membership-settings" "How can members join this group?")
    (:input :type "radio"
            :name "membership-method"
            :class "membership-settings"
            :value "group-admin-approval"
            :onclick (when auto-submit "this.form.submit()")
            :checked (unless (string= current "invite-only") ""))
    "Anyone can request to join this group. Admins can invite people to join and approve/deny membership requests."
    (:br)
    (:input :type "radio"
            :name "membership-method"
            :class "membership-settings"
            :value "invite-only"
            :onclick (when auto-submit "this.form.submit()")
            :checked (when (string= current "invite-only") "checked"))
    "By invitation only. Members must be invited by group admins and cannot request membership."))

(defun identity-selection-html (selected groups &key (class "identity") onchange (userid *userid*))
"Groups should be an a-list of (groupid . group-name)"
  (html
    (:select :id "identity-selection"
             :name "identity-selection"
             :class class
             :onchange onchange
      (:option :value userid
               :selected (when (eql selected userid) "")
               (str (or (getf *user* :name)
                        ;; for unsubscribing emails for non-logged in users
                        (db userid :name)))
               " ")
      (dolist (group (safe-sort groups #'string< :key #'cdr))
        (htm (:option :value (car group)
                      :selected (when (eql selected (car group)) "")
                      (str (cdr group))" "))))))

(defun expiration-selection-html (selected)
  (html
    (:select :id "expiration"
             :name "expiration"
             :class (when (string= (get-parameter-string "focus")
                                       "expiration")
                          "focus")
      (dolist (option '("1-week" "1-month" "3-months" "1-year" "3-years"))
        (htm (:option :value option
                      :selected (when (equalp selected option) "")
                      (str (ppcre:regex-replace-all "-" option " "))))))))

(defun expiration-options (&optional current-expiration
                           &aux (now (get-universal-time))
                                options
                                selected)
  (setf options (list (cons "1-week" (+ now +week-in-seconds+))
                (cons "1-month" (+ now (* 30 +day-in-seconds+)))
                (cons "3-months" (+ now (* 13 +week-in-seconds+)))
                (cons "1-year" (+ now +year-in-seconds+))
                (cons "3-years" (+ now (* 3 +year-in-seconds+)))))
  (when current-expiration
    (setf selected
          ;;pick first option after current-expiration
          (dolist (option
                    (mapcar #'(lambda (option)
                                      (cons (car option)
                                            (- (cdr option)
                                               current-expiration)))
                                  options))
            (when (> (cdr option) 0)
              (return (car option))))))

  (values options selected))

(defun privacy-selection-html (item-type restrictedp my-groups groups-selected &key (class "privacy-selection") onchange)
"Groups should be an a-list of (groupid . group-name)"
  (let* ((my-group-ids (mapcar #'car my-groups))
         (group-ids-user-has-left (set-difference groups-selected my-group-ids))
         (groups-user-has-left (mapcar #'(lambda (id) (cons id (db id :name)))
                                       group-ids-user-has-left)))
    (html
      (:div :id "privacy-selection"
            :class (s+ class (when (and restrictedp
                                        (or groups-user-has-left
                                            (> (length my-groups) 1)))
                               " privacy-selection-details"))
        (:label :for "basic-privacy" "Who can see this " (str item-type) "?")
        (:select :name "privacy-selection"
                 :id "basic-privacy"
                 :class class
                 :onchange onchange
          (:option :value "public"
                   :selected (unless restrictedp "")
                   "Anyone")
          (:option :value "restricted"
                   :selected (when restrictedp "")
                   (str
                     (cond
                      ((= 1 (length my-groups))
                       (s+ (cdar my-groups)
                           (when (= (caar my-groups) +kindista-id+)
                             " account group")
                           " members "))
                      (groups-user-has-left
                       "Groups I'm no longer a member of")
                      (t "People in my groups")))))
        (when restrictedp
          (if (or groups-user-has-left
                  (> (length my-groups) 1))
            (progn
              (dolist (group (safe-sort my-groups #'string-lessp :key #'cdr))
                (htm
                  (:div :class "item-group-privacy"
                    (:input :type "checkbox"
                            :name "groups-selected"
                            :checked (when (or (not groups-selected)
                                               (find (car group) groups-selected))
                                       "checked")
                            :value (car group))
                    (:span (str (cdr group))
                           (str (when (= (car group) +kindista-id+)
                                  " group account "))
                           " members"))))

              ;; for groups the user has left but are still being shown 
              ;; this item
              (dolist (group groups-user-has-left)
                (htm
                  (:br)
                  (:div :class "item-group-privacy"
                    (:input :type "checkbox"
                            :name "groups-selected"
                            :checked (when (member (car group) groups-selected)
                                       "checked")
                            :value (car group)
                            (str (cdr group))
                            (str (when (= (car group) +kindista-id+)
                                 " group account "))
                            " members")))))
            (htm (:input :type "hidden" :name "groups-selected" :value (caar my-groups))))))
      (when (and groups-user-has-left restrictedp)
        (let ((plural (> (length groups-user-has-left) 1)))
          (htm
            (:br)
            (:div :class "privacy-selection-warning"
              (:p
                (:span :class "red" "Warning: ")
                "You are no longer a member of the following group"
                (when plural (str "s"))
                ":"
                (:br)
              (str (format nil *english-list* (mapcar #'cdr groups-user-has-left))))
              (:p "Members of "
                  (str (if plural "those groups" "that group"))
                  " will be able to continue to see this "
                  (str item-type)
                  " until you edit this privacy setting and resave your "
                  (str item-type)
                  "."))))))))

