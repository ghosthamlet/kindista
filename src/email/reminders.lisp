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

(define-constant +week-in-seconds+ 604800)

(defun send-reminder-email (userid title message)
  (let* ((data (db userid))
         (name (getf data :name))
         (email (first (getf data :emails)))
         (html (html-email-base (nth-value 1 (markdown message :stream nil)))))
    (when email
     (cl-smtp:send-email +mail-server+
                         "Kindista <info@kindista.org>"
                         (format nil "\"~A\" <~A>" name email)
                         title
                         message
                         :html-message html))))

(defun invitee-count (id)
  (+ (or (awhen (unconfirmed-invitations id) (length it)) 0)
     (or (length (gethash id *invited-index*)) 0)))

(defun send-all-reminders ()
  (let ((complete-profile (read-file-into-string (s+ +markdown-path+ "reminders/complete-profile.md")))
        (closing (read-file-into-string (s+ +markdown-path+ "reminders/closing.md")))
        (first-gratitude (read-file-into-string (s+ +markdown-path+ "reminders/first-gratitude.md")))
        (first-invitations (read-file-into-string (s+ +markdown-path+ "reminders/first-invitations.md")))
        (first-offers (read-file-into-string (s+ +markdown-path+ "reminders/first-offers.md")))
        (first-requests (read-file-into-string (s+ +markdown-path+ "reminders/first-requests.md")))
        (minimal-activity (read-file-into-string (s+ +markdown-path+ "reminders/minimal-activity.md")))
        (more-gratitude (read-file-into-string (s+ +markdown-path+ "reminders/more-gratitude.md")))
        (more-invitees (read-file-into-string (s+ +markdown-path+ "reminders/more-invitees.md")))
        (more-offers (read-file-into-string (s+ +markdown-path+ "reminders/more-offers.md")))
        (more-requests (read-file-into-string (s+ +markdown-path+ "reminders/more-requests.md")))
        (no-avatar (read-file-into-string (s+ +markdown-path+ "reminders/no-avatar.md")))
        (offers-requests (read-file-into-string (s+ +markdown-path+ "reminders/offers-requests.md"))))

    (dolist (userid *active-people-index*)
      (let* ((person (db userid))
             (name (getf person :name))
             (notify (getf person :notify-reminders))
             (avatar (getf person :avatar))
             (greeting (format nil "Hi ~a,~c~c" name #\return #\linefeed))
             (reminders (getf person :activity-reminders))
             ;reminders is an assoc list where each entry is:
             ;  (reminder-type . time-reminder-was-sent)
             (invitee-count (invitee-count userid))
             (now (+ (get-universal-time)))
             (recent-reminder (first reminders))
             (recent-reminder-time (or (cdr recent-reminder) now))
             (location (getf person :location))
             (activity (gethash userid *activity-person-index*))
             (latest-gratitude (loop for result in activity
                                     when (and (eq (result-type result) :gratitude)
                                               (= userid (first (result-people result))))
                                     return result))
             (latest-offer (find :offer activity :key #'result-type))
             (latest-request (find :request activity :key #'result-type)))

       (when (and notify
                  (or (and (eql reminders nil)
                           ;first reminder after 1 day
                           (> (- now (getf person :created)) 86400))
                      ;remind people at most every 2 weeks
                      (> (- now recent-reminder-time) (* 2 +week-in-seconds+))))
         (cond

           ; complete-profile
           ((and (not location)
                 ;remind to finish profile at most every 3 weeks
                 (or (eql (assoc :complete-profile reminders) nil)
                     (> (- now (cdr (assoc :complete-profile reminders)))
                        (* 3 +week-in-seconds+)))
                 )
              (send-reminder-email userid
                                   (s+ name ", please finish your Kindista profile.")
                                   (concatenate 'string greeting
                                                        complete-profile
                                                        first-invitations
                                                        first-offers
                                                        closing))
              (amodify-db userid :activity-reminders
                                 (acons :complete-profile
                                        now
                                        (remove (assoc :complete-profile it) 
                                          it)))
           )

           ; no-inventory
           ((and (not latest-offer)
                 (not latest-request)
                     ;encourage people to add offers/requests twice a year
                 (or (eql (assoc :no-inventory reminders) nil)
                     (> (- now (cdr (assoc :no-inventory reminders)))
                        (* 13 +week-in-seconds+))))

            (send-reminder-email userid
                                 "Getting started with offers and requests on Kindista"
                                 (concatenate 'string greeting
                                                      offers-requests
                                                      closing))
            (amodify-db userid :activity-reminders
                               (acons :no-inventory
                                      now
                                      (remove (assoc :no-inventory it) 
                                        it)))
           )

           ; minimal-activity
           ((and (or (not latest-offer)
                     (not latest-request)
                     (not latest-gratitude)
                     (not avatar)
                     (< invitee-count 1))
                 (or (eql (assoc :minimal-activity reminders) nil)
                     (> (- now (cdr (assoc :minimal-activity reminders)))
                        (* 5 +week-in-seconds+))))
            (send-reminder-email userid
                                 "Making Kindista work for you"
                                 (concatenate 'string greeting
                                                      minimal-activity
                                                      (or (unless latest-offer
                                                                  first-offers)
                                                          (unless latest-request
                                                                  first-requests))
                                                      (unless (> invitee-count
                                                                 0)
                                                        first-invitations)
                                                      (unless latest-gratitude
                                                              first-gratitude)
                                                      (unless avatar no-avatar)
                                                      closing))
              (amodify-db userid :activity-reminders
                                 (acons :minimal-activity
                                        now
                                        (remove (assoc :minimal-activity it) 
                                          it)))
            )

           ; more-gratitude
           ((and latest-gratitude
                 (> (- now (result-time latest-gratitude)) (* 26 +week-in-seconds+))
                 (or (eql (assoc :more-gratitude reminders) nil)
                     (> (- now (cdr (assoc :more-gratitude reminders)))
                        (* 12 +week-in-seconds+)))
                 )
            (send-reminder-email userid
                                 "Who are you grateful for these days?"
                                 (concatenate 'string greeting
                                                      more-gratitude
                                                      closing))
            (amodify-db userid :activity-reminders
                               (acons :more-gratitude
                                      now
                                      (remove (assoc :more-gratitude it) 
                                        it)))
           )

           ; more-offers
           ((and latest-offer
                 (> (- now (result-time latest-offer)) (* 26 +week-in-seconds+))
                 (or (eql (assoc :more-offers reminders) nil)
                     (> (- now (cdr (assoc :more-offers reminders)))
                        (* 12 +week-in-seconds+))))
            (send-reminder-email userid
                                 "Do you have anything new to offer on Kindista?"
                                 (concatenate 'string greeting
                                                      more-offers
                                                      closing))
            (amodify-db userid :activity-reminders
                               (acons :more-offers
                                      now
                                      (remove (assoc :more-offers it) 
                                        it)))
           )

           ; more-invitees
           ((or (and (< invitee-count 10)
                     (or (eql (assoc :more-invitees reminders) nil)
                         (> (- now (cdr (assoc :more-invitees reminders)))
                            (* 26 +week-in-seconds+))))
                (and (or (< invitee-count 20)
                         (< (length (getf person :following)) 30))
                     (or (eql (assoc :more-invitees reminders) nil)
                         (> (- now (cdr (assoc :more-invitees reminders)))
                            (* 52 +week-in-seconds+)))))
            (send-reminder-email userid
                                 "Help Kindista grow by inviting more friends!"
                                 (concatenate 'string greeting
                                                      more-invitees
                                                      closing))
            (amodify-db userid :activity-reminders
                               (acons :more-invitees
                                      now
                                      (remove (assoc :more-invitees it) 
                                        it)))
           )

           ; more-requests
           ((and latest-request
                 (> (- now (result-time latest-request)) (* 26 +week-in-seconds+))
                 (or (eql (assoc :more-requests reminders) nil)
                     (> (- now (cdr (assoc :more-requests reminders)))
                        (* 12 +week-in-seconds+))))
            (send-reminder-email userid
                                 "What could make your life easier or more enjoyable?"
                                 (concatenate 'string greeting
                                                      more-requests
                                                      closing))
            (amodify-db userid :activity-reminders
                               (acons :more-requests
                                      now
                                      (remove (assoc :more-requests it) 
                                        it)))
           )
           ))))))