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

(defun create-group (&key name creator lat long address street city state country zip location-privacy category membership-method)
  (insert-db `(:type :group
               :name ,name
               :creator ,creator
               :admins ,(list creator)
               :active t
               :location t
               :lat ,lat
               :long ,long
               :address ,address
               :street ,street
               :city ,city
               :state ,state
               :country ,country
               :zip ,zip
               :category ,category
               :membership-method ,membership-method
               :location-privacy ,location-privacy
               :notify-message ,(list creator)
               :notify-gratitude ,(list creator)
               :notify-reminders ,(list creator)
               :notify-invite-request ,(list creator)
               :created ,(get-universal-time))))

(defun index-group (id data)
  (let ((result (make-result :id id
                             :latitude (getf data :lat)
                             :longitude (getf data :long)
                             :type :group
                             :people (append (getf data :admins)
                                             (getf data :members))
                             :time (getf data :created)))
        (name (getf data :name)))

    (with-locked-hash-table (*db-results*)
      (setf (gethash id *db-results*) result))

    (setf (gethash (getf data :username) *username-index*) id)

    (with-locked-hash-table (*group-priviledges-index*)
      (dolist (person (getf data :admins))
        (push id (getf (gethash person *group-priviledges-index*) :admin)))
      (dolist (person (getf data :members))
        (push id (getf (gethash person *group-priviledges-index*) :member))))

    (with-locked-hash-table (*group-members-index*)
      (dolist (person (getf data :admins))
        (push person (gethash id *group-members-index*)))
      (dolist (person (getf data :members))
        (push person (gethash id *group-members-index*))))

    (with-locked-hash-table (*profile-activity-index*)
      (asetf (gethash id *profile-activity-index*)
             (sort (push result it) #'> :key #'result-time)))

    (unless (< (result-time result) (- (get-universal-time) 2592000))
      (with-mutex (*recent-activity-mutex*)
        (push result *recent-activity-index*)))

    (when (and (getf data :lat)
               (getf data :long)
               (getf data :created)
               (getf data :active))

      (metaphone-index-insert (list name) result)
      (geo-index-insert *groups-geo-index* result) 

      (unless (< (result-time result) (- (get-universal-time) 15552000))
        (geo-index-insert *activity-geo-index* result)))))

(defun reindex-group-location (id)
  ;when groups change locations
  (let* ((result (gethash id *db-results*))
         (data (db id))
         (lat (getf data :lat))
         (long (getf data :long)))

    (unless result
      (notice :error :note "no db result on reindex-group-location"))

    (geo-index-remove *groups-geo-index* result)
    (geo-index-remove *activity-geo-index* result)

    (setf (result-latitude result) lat)
    (setf (result-longitude result) long)

    (when (and lat long
               (getf data :created)
               (getf data :active))

      (metaphone-index-insert (list (getf data :name)) result)
      (geo-index-insert *groups-geo-index* result)

      (unless (< (result-time result) (- (get-universal-time) 15552000))
        (geo-index-insert *activity-geo-index* result))

      (dolist (id (gethash id *request-index*))
        (let ((result (gethash id *db-results*)))
          (geo-index-remove *request-geo-index* result)
          (geo-index-remove *activity-geo-index* result)
          (setf (result-latitude result) lat)
          (setf (result-longitude result) long)
          (unless (< (result-time result) (- (get-universal-time) 15552000))
            (geo-index-insert *activity-geo-index* result))
          (geo-index-insert *request-geo-index* result)))

      (dolist (id (gethash id *offer-index*))
        (let ((result (gethash id *db-results*)))
          (geo-index-remove *offer-geo-index* result)
          (geo-index-remove *activity-geo-index* result)
          (setf (result-latitude result) lat)
          (setf (result-longitude result) long)
          (geo-index-insert *offer-geo-index* result)
          (unless (< (result-time result) (- (get-universal-time) 15552000))
            (geo-index-insert *activity-geo-index* result))))

      (dolist (id (gethash id *gratitude-index*))
        (let ((result (gethash id *db-results*)))
          (geo-index-remove *activity-geo-index* result)
          (setf (result-latitude result) lat)
          (setf (result-longitude result) long)
          (unless (< (result-time result) (- (get-universal-time) 15552000))
            (geo-index-insert *activity-geo-index* result)))))))

(defun reindex-group-name (id)
  (metaphone-index-insert (list (db id :name))
                          (gethash id *db-results*)))

(defun change-person-to-group (groupid admin-id)

  (awhen (db groupid :emails)
    (with-locked-hash-table (*email-index*)
      (dolist (email it)
        (remhash email *email-index*))))

  (modify-db groupid :type :group
                     :creator admin-id
                     :admins (list admin-id)
                     :notify-gratitude (list admin-id)
                     :notify-reminders (list admin-id)
                     :notify-invite-request (list admin-id)
                     :notify-message nil
                     :notify-kindista nil
                     :notify-expired-invites nil
                     :emails nil
                     :pass nil)
  ;move all the group's messages into the admin's mailbox
  (flet ((remove-groupid (item)
           (if (listp item)
             (remove groupid item)
             item)))
    (let (completed)
      (doplist (folder messages (gethash groupid *person-mailbox-index*))
        (dolist (message messages)
          (unless (member message completed)
            (let ((id (message-id message))
                  (new-mailbox (cons admin-id groupid))
                  (people (mapcar #'caar (message-people message)))
                  (mailboxes (copy-list (message-people message)))
                  (folders (copy-list (message-folders message))))

              (asetf (car (assoc (list groupid) mailboxes :test #'equal))
                     new-mailbox)
             ;(asetf mailboxes
             ;       (remove (assoc (list admin-id) it :test #'equal)
             ;                it :test #'equal))

              (if (and (member groupid people)
                       (member admin-id people))
                (asetf folders (mapcar #'remove-groupid it))
                (asetf folders (subst admin-id groupid it)))

              (index-message id (modify-db id :message-folders folders
                                              :people mailboxes))
              (dolist (comment (gethash id *comment-index*))
                (when (eq (car (db comment :by)) groupid)
                  (modify-db comment :by new-mailbox)))
             (push message completed)))))))

  (index-group groupid (db groupid))
  (reindex-group-location groupid)
  (reindex-group-name groupid))

(defun change-group-category (groupid &key new-type)
  (let* ((standard-category (post-parameter-string "group-category"))
         (custom-category (post-parameter-string "custom-group-category"))
         ;;new-type is a way to change group-type from the back end
         (next (or (post-parameter "next")
                   (referer)))
         (newtype (or new-type custom-category standard-category)))
    (pprint next)
    (terpri)
    (if (and (string= standard-category "other")
             (not custom-category))
      (see-other (url-compose next "group-category" "other"))
      (progn (modify-db groupid :category newtype)
             (see-other next)))))

(defun group-members (groupid)
  (gethash groupid *group-members-index*))

(defun add-group-member (personid groupid)
  (amodify-db groupid :members (pushnew personid it))
  (with-locked-hash-table (*group-members-index*)
     (pushnew personid (gethash personid *group-members-index*)))
  (with-locked-hash-table (*group-priviledges-index*)
     (pushnew groupid (getf (gethash personid *group-priviledges-index*) :member))))

(defun remove-group-member (personid groupid)
  (amodify-db groupid :members (remove personid it))
  (with-locked-hash-table (*group-priviledges-index*)
     (asetf (getf (gethash personid *group-priviledges-index*) :member)
            (remove groupid it)))
  (with-locked-hash-table (*group-members-index*)
     (asetf (gethash groupid *group-members-index*)
            (remove personid it))))

(defun add-group-admin (personid groupid)
  (assert (eql (db personid :type) :person))
  (with-locked-hash-table (*group-priviledges-index*)
     (asetf (getf (gethash personid *group-priviledges-index*) :admin)
            (pushnew groupid it))
     (asetf (getf (gethash personid *group-priviledges-index*) :member)
            (remove groupid it)))
  (if (member personid (db groupid :members))
    (amodify-db groupid :members (remove personid it)
                        :admins (pushnew personid it))
    (amodify-db groupid :admins (pushnew personid it))))

(defun remove-group-admin (personid groupid)
  (assert (eql (db personid :type) :person))
  (with-locked-hash-table (*group-priviledges-index*)
     (asetf (getf (gethash personid *group-priviledges-index*) :admin)
            (remove groupid it))
     (asetf (getf (gethash personid *group-priviledges-index*) :member)
            (pushnew groupid it)))
  (amodify-db groupid :admins (remove personid it)
                      :members (pushnew personid it)))

(defun group-activity-html (groupid &key type)
  (profile-activity-html groupid :type type
                                 :right (group-sidebar groupid)))

(defun groups-with-user-as-admin (&optional (userid *userid*))
"Returns an a-list of (groupid . group-name)"
  (loop for id in (getf (if (eql userid *userid*)
                          *user-group-priviledges*
                          (gethash userid *group-priviledges-index*))
                        :admin)
        collect (cons id (db id :name))))


(defun groups-with-user-as-member (&optional (userid *userid*))
"Returns an a-list of (groupid . group-name)"
  (loop for id in (getf (if (eql userid *userid*)
                          *user-group-priviledges*
                          (gethash userid *group-priviledges-index*))
                        :member)
        collect (cons id (db id :name))))

(defun group-admin-p (groupid &optional (userid *userid*))
  (member groupid (getf (if (eql userid *userid*)
                          *user-group-priviledges*
                          (gethash userid *group-priviledges-index*)) :admin)))

(defun group-member-links (groupid &key ul-class)
  (let* ((group (db groupid))
         (admins (getf group :admins))
         (members (append admins (getf group :members))))
    (labels ((admin-p (id)
               (not (null (member id admins))))
             (member-less-p (m1 m2)
               (cond
                 ((eql (admin-p (first m1))
                       (admin-p (first m2)))
                  (string-lessp (second m1) (second m2)))
                 ((admin-p (first m1))
                  t)
                 (t
                  nil)))
             (triple (id)
               (let ((name (db id :name)))
                 (list id name (person-link id)))))
      (html
        (:ul :class (or ul-class "")
          (dolist (list (sort (mapcar #'triple members) #'member-less-p))
            (htm
              (:li (str (third list))
               (when (admin-p (first list))
                 (htm " (admin)"))))))))))

(defun group-sidebar (groupid)
  (html
    (when (group-admin-p groupid)
      (htm (:div :class "item right only"
             (:a :href (strcat "/groups/" groupid "/invite-members")
              "+add group members")))
      (str (membership-requests groupid :class "people item right only")))
    (str (members-sidebar groupid))))

(defun invite-group-members (groupid)
  (standard-page
    "Invite group members"
    (html
      (:div :class "invite-members"
        (:h3 "Invite "
             (when (get-parameter "add-another")
               (htm "more "))
             "people to join "
         (str
           (if (eq groupid +kindista-id+)
             "Kindista's group account"
             (db groupid :name))))
        (:form :method "get"
               :action (strcat "/groups/" groupid "/invite-members")
         (:input :type "text"
                 :name "search-name"
                 :placeholder "Search by name")
         (:button :class "submit yes" :name "add-member" :type "submit" "Search"))
        (awhen (get-parameter "search-name")
          (let ((results (search-people it)))
            (if results
              (dolist (result results)
                (htm
                  (:form :method "post"
                       :class "invite-member-result"
                       :action (strcat "/groups/" groupid)
                     (str
                       (person-card
                         (car result)
                         (cdr result)
                         :button (html (:button :class "submit yes"
                                                :name "invite-member"
                                                :value (car result)
                                                :type "submit"
                                                "Invite")))))))
              (htm
                (:p
                  "There are no Kindista members with the name "
                  (str it)
                  " .  Please try again.")))))))
    :top (simple-profile-top groupid)
    :selected "groups"))

(defun membership-requests (groupid &key (class ""))
  (let ((requests (gethash groupid *group-membership-requests-index*)))
    (when requests
      (html
        (:div :class (s+ "membership-requests " class)
          (:h3 "Membership requests")
            (dolist (request requests)
              (let* ((personid (car request))
                     (link (s+ "/people/" (username-or-id personid))))
                (htm
                  (:div :class "membership-request"
                    (:div :class "avatar"
                      (str
                        (v-align-middle
                          (:a :href link
                            (:img :src (get-avatar-thumbnail personid 70 70))))))
                    (:div :class "member-approval"
                      (str
                        (v-align-middle
                          (:form :class "member-approval-ui"
                                 :method "post"
                                 :action (strcat "/groups/" groupid)
                             (:input :type "hidden"
                                     :name "membership-request-id"
                                     :value (cdr request))
                             (:button :class "yes small"
                                      :type "submit"
                                      :name "approve-group-membership-request"
                                      "approve")
                             (:button :class "cancel small"
                                      :type "submit"
                                      :name "deny-group-membership-request"
                                      "deny")))))
                    (:div :class "request-name"
                      (str (v-align-middle
                             (str (person-link personid))))))))))))))

(defun members-sidebar (groupid)
  (html
    (:div :class "people item right only"
      (:h3 "Group members")
      (str (group-member-links groupid)))))

(defun profile-group-members-html (groupid)
  (let* ((group (db groupid))
         (strid (username-or-id groupid))
         (membership-requests (membership-requests groupid :class "item members-tab"))
         (*base-url* (strcat "/groups/" strid)))
    (standard-page
      (getf group :name)
      (html
        (when *user* (str (profile-tabs-html groupid :tab :members)))
        (:div :class "activity"
          (when (group-admin-p groupid)
            (htm
              (:div :class "members-tab invite-members"
               (:a :href (strcat "/groups/" groupid "/invite-members")
                   :class "float-right"
                  "+add group members")))
            (when membership-requests
              (str membership-requests))
            (htm (:h3 "Current Members")))
          (str (group-member-links groupid :ul-class "members-tab current-members"))))
      :top (profile-top-html groupid)
      :selected "groups")))

(defun group-activity-selection-html (groupid group-name selected tab)
  (html
    (:form :method "get"
           :class "group-activity-selection small"
           :action (strcat "/groups/" (username-or-id groupid) "/" tab)
      (:strong "Display "
               (str (cond
                     ((or (string= tab "activity")
                          (string= tab "offers")
                          (string= tab "requests"))
                      (s+ tab " from "))
                     ((string= tab "reputation")
               "gratitude about "))))
      (:div
        (:div
          (:input :type "checkbox"
                :name "group"
                :onchange "this.form.submit()"
                :value (str (when (or (string= selected "all")
                                      (string= selected "group"))
                               "checked")))
           (:label :for "group" (str group-name)))
         (:div
           (:input :type "checkbox"
                   :name "members"
                   :onchange "this.form.submit()"
                   :value (str (when (or (string= selected "all")
                                         (string= selected "members"))
                                 "checked")))
           (:label :for "group" (str (s+ "members of " group-name)))))
       " "
       (:input :type "submit" :class "no-js" :value "apply"))))

(defun group-member-activity (group-members &key type count)
  (let ((count (or count (+ 20 (floor (/ 30 (length group-members))))))
        (i 0)
        (activity nil))
    (dolist (person group-members)
      (setf i 0)
      (loop for result in (remove-private-items
                            (gethash person *profile-activity-index*))
            while (< i count)
            when (or (not type)
                     (if (eql type :gratitude)
                       (or (and (eql :gratitude (result-type result))
                                (not (eql person (first (result-people result)))))
                           (and (eql :gift (result-type result))
                                (not (eql person (car (last (result-people result)))))))
                       (eql type (result-type result))))
            do (progn
                 (if activity
                   (asetf activity (sort (push result it) #'< :key #'activity-rank))
                   (asetf activity (list result)))
                 (incf i))))
    activity))

(defun get-groups ()
  (if (and *user*
           (> (+ (length (getf *user-group-priviledges* :admin))
                 (length (getf *user-group-priviledges* :member)))
              0))
    (see-other "/groups/my-groups")
    (see-other "/groups/nearby")))

(defun get-my-groups ()
  (if *user*
    (let ((admin-groups (groups-with-user-as-admin))
          (member-groups (groups-with-user-as-member)))
      (standard-page
        "My Groups"
        (html
          (str (menu-horiz "actions" (html (:a :href "/groups/new" "create a new group"))))
          (str (groups-tabs-html :tab :my-groups))
          (unless (or admin-groups member-groups)
            (htm (:h3 "You have not joined any groups yet.")))
          (dolist (group (sort admin-groups #'string-lessp :key #'cdr))
            (str (group-card (car group))))
          (dolist (group (sort member-groups #'string-lessp :key #'cdr))
            (str (group-card (car group)))))
        :selected "groups"
        :right (html
                 (str (donate-sidebar))
                 (str (invite-sidebar)))))

      (see-other "groups/nearby")))

(defun get-groups-nearby ()
  (nearby-profiles-html "groups" (groups-tabs-html :tab :nearby)))

(defun get-groups-new ()
  (require-active-user
    (if (getf *user* :pending)
      (progn
        (pending-flash "create group profiles on Kindista")
        (see-other (or (referer) "/home")))
      (enter-new-group-details))))

(defun enter-new-group-details (&key error location name public-location membership-method)
  (standard-page
    "Create a group profile"
    (html
      (when error
        (flash error :error t))
      (:div :class "item"
        (:h2 "Create a Kindista profile for your group")
        (:div :class "item create-group"
          (:form :method "post" :action "/groups/new"
            (:div
              (:label "Group name")
              (:input :type "text"
                      :name "name"
                      :placeholder (escape-for-html "Enter your group's name")
                      :value (awhen name (escape-for-html it))))
            (:div
              (:label "Group location")
              (:input :type "text"
                      :name "location"
                      :placeholder (escape-for-html "Enter your group's address")
                      :value (awhen location (escape-for-html it)))
              (:br)
              (:input :type "checkbox"
                      :name "public-location"
                      :value (str (when public-location "checked")))
              "Display this address publicly to anyone looking at this group's profile page.")
            (:p (:em "Please note: you will be able to change the visibiity of your group's address on its settings page."))

            (:h3 "What kind of a group is this?")
            (:div :class "group-category-selection"
              (str
                (group-category-selection :auto-submit 'onclick
                                          :submit-buttons nil
                                          :class "new-group identity"
                                          :selected (or (post-parameter "group-category")
                                                        (post-parameter "custom-group-category")))))
            (:div :class "long"
              (str (group-membership-method-selection membership-method)))

           (:button :class "cancel"
                    :type "submit"
                    :name "cancel"

                    "Cancel")
           (:button :class "yes"
                    :type "submit"
                    :value "1"
                    :name "create-group"
                    "Create")))))))

(defun post-groups-new ()
  (let ((location (post-parameter-string "location"))
        (name (when (scan +text-scanner+ (post-parameter "name"))
                (post-parameter "name")))
        (lat (post-parameter-float "lat"))
        (long (post-parameter-float "long"))
        (city (post-parameter-string "city"))
        (state (post-parameter-string  "state"))
        (country (post-parameter-string "country"))
        (street (awhen (post-parameter "street")
                  (unless (or (string= it "")
                              (equalp it "nil nil"))
                 it)))
        (zip (post-parameter-string "zip"))
        (group-category (or (post-parameter-string "custom-group-category")
                            (post-parameter-string "group-category")))
        (membership-method (post-parameter-string "membership-method"))
        (public (when (post-parameter "public-location") t)))

    (labels ((try-again (&optional e)
               (enter-new-group-details :name (post-parameter "name")
                                        :location location
                                        :membership-method membership-method
                                        :error e))
             (new-group ()
               (see-other
                 (strcat "/groups/"
                         (create-group :name name
                                       :creator *userid*
                                       :lat lat
                                       :long long
                                       :address location
                                       :street street
                                       :city city
                                       :state state
                                       :country country
                                       :zip zip
                                       :category (awhen group-category
                                                   (unless (string= "other"
                                                                    it)
                                                     it))
                                       :membership-method (if (string= membership-method
                                                                       "invite-only")
                                                            :invite-only
                                                            :group-admin-approval)
                                       :location-privacy (if public
                                                           :public
                                                           :private)))))

             (confirm-location ()
               (multiple-value-bind (clat clong caddress ccity cstate ccountry cstreet czip)
                 (geocode-address location)
                 (verify-location "/groups/new"
                                  "Please verify your group's location."
                                  clat
                                  clong
                                  "name" name
                                  "location" caddress
                                  "city" ccity
                                  "state" cstate
                                  "country" ccountry
                                  "street" cstreet
                                  "zip" czip
                                  "group-category" group-category
                                  "membership-method" membership-method
                                  (when public "public-location")
                                  (when public "t")))))

      (cond
        ((getf *user* :pending)
         (pending-flash "create group profiles on Kindista")
         (see-other (or (referer) "/home")))

        ((post-parameter "cancel")
         (see-other "/groups"))

        ((and group-category
              (nor (post-parameter "create-group")
                   (post-parameter "confirm-location")))
         (try-again))

        ((< (length name) 4)
         (try-again "Please use a longer name for your group"))

        ((or (not location)
             (string= location ""))
         (try-again "Please add a location for your group"))

       ((post-parameter "reset-location")
        (enter-new-group-details :name name
                                 :membership-method membership-method))

       ((not (and lat long city state location country zip))
        ;geocode the address
        (confirm-location))

       ((post-parameter "confirm-location")
        (aif (search-groups name :lat lat :long long)
          (confirm-group-uniqueness it name lat long location city state country street zip membership-method :public-location public)
          (new-group)))

       ((and lat long city state location country zip (post-parameter "confirm-uniqueness"))
        (new-group))))))

(defun resend-group-membership-request (request-id)
  (index-message request-id
                 (modify-db request-id :resent (get-universal-time))))

(defun create-group-membership-request (groupid &key (person *userid*))
  (let* ((time (get-universal-time))
         (mailboxes (mailbox-ids (list groupid)))
         (people (mapcar #'(lambda (mailbox) (cons mailbox :unread))
                         mailboxes))
         (id (insert-db (list :type :group-membership-request
                              :group-id groupid
                              :people people ;group admins at time of request
                              :message-folders (list :inbox
                                                     (mapcar #'car mailboxes))
                              :requested-by person
                              :created time))))

    id))

(defun index-group-membership-request (id data)
  (let ((groupid (getf data :group-id)))
    (with-locked-hash-table (*group-membership-requests-index*)
      (asetf (gethash groupid *group-membership-requests-index*)
             (acons (getf data :requested-by) id it))))
  (index-message id data))

(defun delete-group-membership-request (id)
  (let* ((request (db id))
         (group (getf request :group-id)))
    (with-locked-hash-table (*group-membership-requests-index*)
      (asetf (gethash group *group-membership-requests-index*)
             (remove (cons (getf request :requested-by) id)
                     it :test #'equal)))
    (remove-message-from-indexes id)
    (remove-from-db id)))

(defun approve-group-membership-request (id)
  (let* ((request (db id))
         (group (getf request :group-id)))
    (add-group-member (getf request :requested-by) group)
    (delete-group-membership-request id)))

(defun create-group-membership-invitation (groupid invitee &key (host *userid*))
  (let ((id (insert-db (list :type :group-membership-invitation
                             :group-id groupid
                             :people (list (cons (list invitee)  :unread))
                             :message-folders (list :inbox (list invitee))
                             :invited-by host
                             :created (get-universal-time)))))
    id))

(defun resend-group-membership-invitation (invitation-id)
  (index-message invitation-id
                 (modify-db invitation-id :resent (get-universal-time))))

(defun index-group-membership-invitation (id data)
  (let ((groupid (getf data :group-id)))
    (with-locked-hash-table (*group-membership-invitations-index*)
      (asetf (gethash groupid *group-membership-invitations-index*)
             (acons (caaar (getf data :people)) id it))))
  (index-message id data))

(defun accept-group-membership-invitation (id)
  (let* ((invitation (db id))
         (group (getf invitation :group-id))
         (invitee (caaar (getf invitation :people))))
    (add-group-member invitee group)
    (with-locked-hash-table (*group-membership-invitations-index*)
      (asetf (gethash group *group-membership-invitations-index*)
             (remove (cons invitee id) it :test #'equal)))
    (remove-message-from-indexes id)
    (remove-from-db id)))

(defun confirm-group-uniqueness (results name lat long address city state country street zip membership-method &key public-location)
  (standard-page
    "Is your group already on Kindista?"
    (html
      (:div :class "item confirm-unique-group"
        (:h2 "Is your group already on Kindista?")
        (:p "It looks like your group might already on Kindista. "
         "Please do not create another profile for a group that is "
         "already on Kindista. ")
        (:p "If your group is listed below, please click the link to \"join\""
         "it on the group's profile page. "
         "If you believe you should included in the group's admins, "
         "please contact the current admin(s) and ask them to add you as an admin. "
         "Please "
         (:a :href "/contact-us" "let us know")
         " if you have any difficulty with this." )
         (:br)
        (str (groups-results-html results))
        (:form :method "post" :action "/groups/new"
            (:input :type "hidden" :name "name" :value (escape-for-html name))
            (:input :type "hidden" :name "lat" :value lat)
            (:input :type "hidden" :name "long" :value long)
            (:input :type "hidden" :name "location" :value (escape-for-html address))
            (:input :type "hidden" :name "city" :value (escape-for-html city))
            (:input :type "hidden" :name "state" :value state)
            (:input :type "hidden" :name "country" :value (escape-for-html country))
            (:input :type "hidden" :name "street" :value (escape-for-html street))
            (:input :type "hidden" :name "zip" :value zip)
            (:input :type "hidden" :name "membership-method" :value membership-method)
            (when public-location
              (htm (:input :type "hidden" :name "public/location" :value lat)))
            (:button :class "cancel"
                     :type "submit"
                     :name "cancel"
                     "Nevermind, my group is alredy on Kindista!")
            (:button :class "yes"
                     :type "submit" :name "confirm-uniqueness" "My group is not already on Kindista, create a profile"))))))

(defun get-group (id)
  (ensuring-userid (id "/groups/~a")
    (group-activity-html id)))

(defun get-group-about (id)
  (require-user
    (ensuring-userid (id "/groups/~a/about")
      (profile-bio-html id))))

(defun get-group-activity (id)
  (ensuring-userid (id "/groups/~a/activity")
    (group-activity-html id)))

(defun get-group-reputation (id)
  (require-user
    (ensuring-userid (id "/groups/~a/reputation")
      (group-activity-html id :type :gratitude))))

(defun get-group-offers (id)
  (require-user
    (ensuring-userid (id "/groups/~a/offers")
      (group-activity-html id :type :offer))))

(defun get-group-requests (id)
  (require-user
    (ensuring-userid (id "/groups/~a/requests")
      (group-activity-html id :type :request))))

(defun get-group-members (id)
  (require-user
    (ensuring-userid (id "/groups/~a/members")
      (profile-group-members-html id))))

(defun get-invite-group-members (id)
  (ensuring-userid (id "/groups/~a/invite-members")
    (if (group-admin-p id)
      (invite-group-members id)
      (permission-denied))))

(defun groups-tabs-html (&key (tab :my-groups))
  (html
    (:menu :class "bar"
           :id "groups-tabs"
      (:h3 :class "label" "Groups Menu")

      (if (eql tab :my-groups)
        (htm (:li :class "selected" "My Groups"))
        (htm (:li (:a :href "/groups/my-groups" "My Groups"))))

      (if (eql tab :nearby)
        (htm (:li :class "selected" "Nearby"))
        (htm (:li (:a :href "/groups/nearby" "Nearby"))))

     ;(if (eql tab :suggested)
     ;  (htm (:li :class "selected" "Suggested"))
     ;  (htm (:li (:a :href "/people/suggested" "Suggested"))))

     ;(if (eql tab :invited)
     ;  (htm (:li :class "selected" "Invited"))
     ;  (htm (:li (:a :href "/people/invited" "Invited"))))
      )))

(defun post-existing-group (id)
  (require-user
    (let* ((id (parse-integer id))
           (group (db id))
           (url (strcat "/groups/" (username-or-id id)))
           (invitee (awhen (post-parameter "invite-member")
                      (parse-integer it))))
      (cond
        ((post-parameter "request-membership")
         (if (eql (getf group :membership-method) :invite-only)
           (permission-denied)
           (unless (or (member *userid* (getf group :members))
                       (member *userid* (getf group :admins)))
             (let ((current-membership-request (assoc *userid*
                                                      (gethash id
                                                               *group-membership-requests-index*))))
               (aif current-membership-request
                 (resend-group-membership-request (cdr it))
                 (create-group-membership-request id)))))
         (flash (s+ "Your membership request has been forwarded to the "
                    (getf group :name)
                    " admins."))
         (see-other (or (post-parameter "next") url)))

        ((post-parameter "leave-group")
         (when (member *userid* (getf group :members))
           (confirm-action "Leave group"
                           (s+ "Are you sure you want to leave the group " (getf group :name) "?")
                           :url (strcat "/groups/" (username-or-id id))
                           :post-parameter "really-leave-group"
                           :details "If you leave this group, you will not be able to rejoin again without being re-approved by the groups admin.")))

        ((post-parameter "really-leave-group")
         (when (member *userid* (getf group :members))
           (remove-group-member *userid* id)
           (see-other url)))

        (t
          (if (group-admin-p id)
            (cond
              (invitee
               (unless (or (member invitee (getf group :members))
                           (member invitee (getf group :admins)))
                 (let ((invitationp (assoc invitee
                                           (gethash id *group-membership-invitations-index*))))
                   (acond
                     ((assoc invitee
                             (gethash id *group-membership-requests-index*))
                      (approve-group-membership-request (cdr it))
                      (flash (s+ "You have approved "
                                 (db invitee :name)
                                 "'s request to join "
                                 (getf group :name) ".")))
                     (invitationp
                      (resend-group-membership-invitation (cdr it))
                      (flash (s+ (db invitee :name)
                                  "'s invitation has been resent.")))
                     (t
                      (create-group-membership-invitation id invitee)
                      (flash (s+ "An invitation has been sent to "
                                 (db invitee :name) "."))))))
               (see-other (or (post-parameter "next")
                              (url-compose (s+ url "/invite-members")
                                           "add-another" ""))))

              ((post-parameter-string "group-category")
               (change-group-category id))

              ((post-parameter "membership-method")
               (modify-db id :membership-method (if (string= (post-parameter "membership-method")
                                                             "invite-only")
                                                  :invite-only
                                                  :group-admin-approval))
               (see-other (referer)))
              ((post-parameter "approve-group-membership-request")
               (approve-group-membership-request
                 (parse-integer (post-parameter "membership-request-id")))
               (see-other (referer)))

              ((post-parameter "deny-group-membership-request")
               (delete-group-membership-request
                 (parse-integer (post-parameter "membership-request-id")))
               (see-other (referer)))

              ((post-parameter "confirm-new-admin")
               (if (< (length (getf group :admins)) 3)
                 (add-group-admin (parse-integer (post-parameter "item-id")) id)
                 (flash (s+ "This account already has the maximum of three administrators. "
                            "If you would like to add an additional admin for this account, one "
                            "of the current admins must first revoke their admin priviledges.")
                        :error t))
               (see-other (url-compose "/settings/admin-roles"
                                       "groupid" id)))

              ((post-parameter "confirm-revoke-admin-role")
               (if (member *userid* (getf group :admins))
                 (progn
                   (remove-group-admin *userid* id)
                   (flash (s+ "You are no longer an admin for " (getf group :name) "'s account")))
                 (permission-denied))
               (see-other url)))

            (permission-denied)))))))
