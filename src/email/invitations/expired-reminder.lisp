;;; Copyright 2012-2013 CommonGoods Network, Inc.
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

(defun send-expired-invitations-reminder-email (userid email-list)
  (let* ((host (db userid))
         (host-email (car (getf host :emails)))
         (unsubscribe-key (getf host :unsubscribe-key))
         (name (getf host :name))
         (expired-count (length email-list)))
    (cl-smtp:send-email +mail-server+
                        "Kindista <noreply@kindista.org>"
                        host-email
                        (if (> expired-count 1)
                            (strcat expired-count " of your Kindista invitations have expired")
                            "One of your Kindista invitations has expired")
                        (expired-invitations-reminder-text name
                                                           email-list
                                                           expired-count
                                                           host-email
                                                           unsubscribe-key)
                        :html-message (expired-invitations-reminder-html
                                        name
                                        email-list
                                        expired-count
                                        host-email
                                        unsubscribe-key))))

(defun expired-invitations-reminder-text
  (name email-list expired-count host-email unsubscribe-key)
(strcat*
"Hi " name ","
#\linefeed #\linefeed
"We're writing to let you know that the Kindista invitation"
(if (> expired-count 1)
"s you sent to the following email addresses have expired:"
" you sent to the following email address has expired:")
#\linefeed #\linefeed
(dolist (email email-list)
  (format nil "~a~c~c" email #\return #\linefeed))
#\linefeed
" You can send them another invitation or delete the invitation if you don't think they are going to join: "
#\linefeed
+base-url+ "people/invited"
#\linefeed #\linefeed
" Thanks for helping spread the word about Kindista!"
#\linefeed
"-The Kindista Team"
#\linefeed #\linefeed #\linefeed
(unsubscribe-notice-ps-text unsubscribe-key
                            host-email
                            "notifications when invitations you send for people to join Kindista expire"
                            :detailed-notification-description "these notifications"
                            :unsub-type "expired-invites")
))

(defun expired-invitations-reminder-html
  (name email-list expired-count host-email unsubscribe-key)
  (html-email-base
    (html
      (:p :style *style-p*
        "Hi " (str name) ",")

      (:p :style *style-p*
       "We're writing to let you know that the Kindista invitation"
       (str (if (> expired-count 1)
              "s you sent to the following email addresses have expired:"
              " you sent to the following email address has expired:")))

      (:ul
        (dolist (email email-list)
          (htm (:li (str email)))))

      (:p :style *style-p*
        "You can send them another invitation or delete the invitation if you don't think "
        "they are going to join: "
        (:br)
        (:a :href (url-compose (s+ +base-url+ "people/invited"))
                  (str (s+ +base-url+ "people/invited"))))

      (:p :style *style-p*
        "Thanks for helping spread the word about Kindista!")

      (:p "-The Kindista Team")

      (str (unsubscribe-notice-ps-html
             unsubscribe-key
             host-email
             "notifications when invitations you send for people to join Kindista expire"
             :detailed-notification-description "these notifications"
             :unsub-type "expired-invites")))))

