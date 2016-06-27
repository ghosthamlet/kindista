;;; Copyright 2015-2016 CommonGoods Network, Inc.
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

(defparameter *fb-graph-url* "https://graph.facebook.com/")

(defvar *facebook-app-token* nil)
(defvar *facebook-user-token* nil)
(defvar *facebook-user-token-expiration* nil)
(defvar *fb-id* nil)

(defun reassign-fb-action-ids ()
  "Utility function. Should only be run once."
  (dolist (userid '(1 33383 33385))
    (dolist (result (gethash userid *profile-activity-index*))
      (let* ((item-id (result-id result))
             (data (db item-id)))
        (awhen (getf data :fb-action-id)
          (modify-db item-id
                     :fb-action-id nil
                     :fb-actions (list
                                   (list
                                     :fb-id (db userid :fb-id)
                                     :fb-action-type (case (getf data :type)
                                                       (:gratitude "express")
                                                       (t "post"))
                                     :fb-action-id it))))))))

(defun get-facebook-app-token ()
    (string-left-trim "access_token="
      (http-request
        (url-compose "https://graph.facebook.com/oauth/access_token"
                     "client_id" *facebook-app-id*
                     "client_secret" *facebook-secret*
                     "grant_type" "client_credentials"))))

(defmacro with-facebook-credentials (&body body)
  `(let ((*fb-id* (getf *user* :fb-id))
         (*facebook-user-token* (getf *user* :fb-token))
         (*facebook-user-token-expiration* (getf *user* :fb-expires)))
     ,@body))

(defun facebook-item-meta-content
  (id
   typestring
   title
   &key description
        determiner
        url
        image)
  (html
    (when typestring
      (htm
        (:meta :property "og:type"
               :content (s+ "kindistadotorg:" typestring))))
    (awhen determiner
      (htm (:meta :property "og:determiner" :content it)))
    (:meta :property "fb:app_id"
           :content *facebook-app-id*)
    (:meta :property "og:url"
           :content (or url
                        (strcat* +base-url+

                                 typestring
                                 (when (or (string= typestring "offer")
                                           (string= typestring "request"))
                                   "s")
                                 "/"
                                 id)))
    (:meta :property "og:title"
           :content (escape-for-html
                      (or title (s+ "Kindista " (string-capitalize typestring)))))
    (awhen description
      (htm (:meta :property "og:description"
                  :content (escape-for-html it))))
    (:meta :property "og:image:secure_url"
           :content (s+ "https://kindista.org" (or image "/media/biglogo4fb.jpg")))
    (:meta :property "og:image"
           :content (s+ "http://media.kindista.org"
                        (aif image
                          (regex-replace "/media" it "")
                          "/biglogo4fb.jpg")))))

(defun facebook-sign-in-button
  (&key (redirect-uri "home")
        (button-text "Sign in with Facebook")
        re-request
        state
        scope)
  (asetf scope
         (strcat* (if (listp scope)
                    (format nil "~{~A,~}" scope)
                    (s+ scope ","))
                  "public_profile,publish_actions,email"))
  (html
    (:a :class "blue"
        :href (apply #'url-compose
                     "https://www.facebook.com/dialog/oauth"
                     (remove nil
                       (append
                         (list "client_id" *facebook-app-id*
                               "scope" scope
                               "response_type" "code,granted_scopes"
                               "redirect_uri" (url-encode
                                                (s+ +base-url+ redirect-uri)))
                         (when re-request
                           (list "auth_type" " rerequest"))
                         (when state
                           (list "state" state)))))
        (str button-text))))

(defun facebook-debugging-log (&rest messages)
  (with-open-file (s (s+ +db-path+ "/tmp/log") :direction :output :if-exists :append)
    (let ((*print-readably* nil))
      (format s "~{~S~%~}" messages))
    (fsync s)))

(defun register-facebook-user
  (&optional (redirect-uri "home")
   &aux reply)
  (when (and *token* (get-parameter "code"))
    (setf reply (multiple-value-list
                  (http-request
                    (url-compose
                      "https://graph.facebook.com/oauth/access_token"
                      "client_id" *facebook-app-id*
                      "redirect_uri" (s+ +base-url+ redirect-uri)
                      "client_secret" *facebook-secret*
                      "code" (get-parameter "code"))
                    :force-binary t)))
    (cond
      ((<= (second reply) 200)
       (quri.decode:url-decode-params (octets-to-string (first reply))))
      ((>= (second reply) 400)
       (facebook-debugging-log
         (cdr (assoc :message
                     (cdr (assoc :error
                                 (decode-json-octets (first reply)))))))
       nil)
      (t
       (with-open-file (s (s+ +db-path+ "/tmp/log") :direction :output :if-exists :supersede)
         (format s ":-("))
       nil))))

(defun check-facebook-user-token
  (&optional (userid *userid*)
             (fb-token *facebook-user-token* )
   &aux (*user* (or *user* (db userid)))
        reply
        data)

  (setf reply
        (multiple-value-list
          (with-facebook-credentials
            (http-request
              (s+ *fb-graph-url* "debug_token")
              :parameters (list (cons "input_token" fb-token)
                                (cons "access_token" *facebook-app-token*))))))

  (when (= (second reply) 200)
    (setf data
          (alist-plist
            (cdr (find :data
                       (decode-json-octets (first reply))
                       :key #'car)))))
  (when (and (string= (getf data :app--id) *facebook-app-id*)
             (eql (safe-parse-integer (getf data :user--id))
                  (getf *user* :fb-id)))
    data))

(defun get-facebook-user-data (fb-token)
  (alist-plist
    (decode-json-octets
      (http-request (strcat *fb-graph-url*
                            "me")
                    :parameters (list (cons "access_token" fb-token)
                                      (cons "method" "get"))))))

(defun get-facebook-user-id (fb-token)
  (safe-parse-integer (getf (get-facebook-user-data fb-token) :id)))

(defun fb-k-id (fb-id)
  (gethash fb-id *facebook-id-index*))

(defun get-facebook-profile-picture
  (k-user-id
   &aux (user (db k-user-id))
        (fb-token (getf user :fb-token))
        (fb-user-id (getf user :fb-id))
        (response))
  (when (and fb-token fb-user-id (getf user :fb-link-active))
   (setf response
         (multiple-value-list
           (http-request (strcat *fb-graph-url* "v2.5/" fb-user-id "/picture")
                         :parameters (list (cons "access_token" fb-token)
                                           (cons "type" "large")
                                           (cons "method" "get")))))
   (when (eql (second response) 200)
     (values (first response)
             (cdr (assoc :content-type (third response)))
             (fourth response)))))

(defun save-facebook-profile-picture-to-avatar (k-userid)
  (multiple-value-bind
    (octet-array content-type image-url)
    (get-facebook-profile-picture k-userid)
    (declare (ignore image-url))
    (create-image octet-array content-type)))

(defun facebook-image-identifyier (k-userid)
  (awhen (third (multiple-value-list (get-facebook-profile-picture k-userid)))
    (car (last (puri:uri-parsed-path it)))))

(defun get-facebook-user-permissions
  (k-id
   &optional (user (db k-id))
   &aux (fb-id (getf user :fb-id))
        response
        current-permissions)
  (when (and fb-id (getf user :fb-link-active))
     (setf response
           (multiple-value-list
             (http-request
               (strcat *fb-graph-url*
                       "v2.5/"
                       fb-id "/permissions")
               :parameters (list (cons "access_token" *facebook-app-token*)
                                 (cons "access_token" (getf user :fb-token))
                                 (cons "method" "get"))))))

  (mapcar
    (lambda (pair)
      (push
        (make-keyword
          (string-upcase (substitute #\- #\_ (car pair))))
        (getf current-permissions (cdr pair))))
    (loop for permission in (getf (alist-plist
                                    (decode-json-octets
                                      (first response)))
                                  :data)
          collect (cons (cdar permission)
                        (if (string= (cdadr permission) "granted")
                          :granted
                          :declined))))
    current-permissions)

(defun check-facebook-permission
  (permission
   &optional (userid *userid*)
   &aux (user (db userid))
        (saved-fb-permissions (getf user :fb-permissions))
        (current-fb-permissions (get-facebook-user-permissions userid user))
        (granted-fb-permissions (getf current-fb-permissions :granted)))
  (when (set-exclusive-or saved-fb-permissions granted-fb-permissions)
    (modify-db userid :fb-permissions granted-fb-permissions))
  (values (find permission granted-fb-permissions)
          (when (find permission (getf current-fb-permissions :declined))
            :declined)))

(defun get-facebook-kindista-friends
  (&optional (k-id *userid*)
   &aux (user (db k-id))
        (fb-id (getf user :fb-id))
        (response))

  (when (and fb-id (getf user :fb-link-active))
    (setf response
          (multiple-value-list
            (http-request
              (strcat *fb-graph-url*
                      "v2.5/"
                      fb-id "/friends")
              :parameters (list (cons "access_token" *facebook-app-token*)
                                (cons "access_token" (getf user :fb-token))
                                (cons "method" "get"))))))
  (when (= (second response) 200)
    (mapcar (lambda (friend)
            (gethash (safe-parse-integer (cdr (find :id friend :key 'car)))
                     *facebook-id-index*))
          (cdr (find :data (decode-json-octets (first response)) :key 'car)))))

(defun active-facebook-user-p
  (&optional (userid *userid*)
             (user (if (eql userid *userid*) *user* (db userid))))
  (and (getf user :fb-id) (getf user :fb-link-active) ))

(defun get-facebook-location-data (fb-location-id fb-token)
  (alist-plist
    (cdr
      (assoc :location
             (decode-json-octets
               (http-request (strcat *fb-graph-url*
                                     "v2.5/"
                                     fb-location-id)
                             :parameters (list (cons "access_token" fb-token)
                                               (cons "access_token" *facebook-app-token*)
                                               (cons "fields" "location")
                                               (cons "method" "get"))))))))

(defun new-facebook-action-notice-handler
  (&aux (notice-data (notice-data))
        (userid (getf notice-data :userid))
        (item-id (getf notice-data :item-id))
        (item (db item-id))
        (action-type (case (getf item :type)
                       (:gratitude "express")
                       (t "post")))
        (fb-action-id)
        (fb-object-id))

  ;; userid is included w/ new publish request but not scraping new data
  (facebook-debugging-log "new-facebook-action" notice-data)
  (when userid
    (setf fb-action-id
          (publish-facebook-action item-id
                                   :userid userid
                                   :item item
                                   :action-type action-type))
    (setf fb-object-id (get-facebook-object-id item-id)))
  (facebook-debugging-log (strcat "fb-object-id: " fb-object-id))
  (cond
    ((getf notice-data :object-modified)
     (scrape-facebook-item (getf notice-data :fb-object-id)))
    (userid
      ;; update kindista DB with new facebook object/action ids
      (http-request
        (s+ +base-url+ "publish-facebook")
        :parameters (list (cons "item-id" (strcat item-id))
                          (cons "fb-action-id" (strcat fb-action-id))
                          (cons "fb-action-type" action-type)
                          (cons "fb-object-id" (strcat fb-object-id))
                          (cons "fb-id" (strcat (db userid :fb-id))))
        :method :post))))

(defun post-new-facebook-data
  (&aux (item-id (post-parameter-integer "item-id"))
        (fb-action-id (post-parameter-integer "fb-action-id"))
        (fb-object-id (post-parameter-integer "fb-object-id"))
        (fb-id (post-parameter-integer "fb-id"))
        (fb-action-type (post-parameter-string "fb-action-type")))
  (if (server-side-request-p)
    (progn
      (facebook-debugging-log
        "modifying the DB"
        (post-parameters*)
        (strcat "fb-object-id: " fb-object-id)
        (amodify-db item-id :fb-object-id fb-object-id
                            :fb-actions (cons (list :fb-id fb-id
                                                    :fb-action-type fb-action-type
                                                    :fb-action-id fb-action-id)
                                              it)))
      (setf (return-code*) +http-no-content+)
      nil)
    (progn
      (setf (return-code*) +http-forbidden+)
      nil)))

(defun publish-facebook-action
  (id
   &key (item (db id))
        (action-type (case (getf item :type)
                       (:gratitude "express")
                       (t "post")))
        (userid *userid*)
   &aux (object-type (string-downcase (symbol-name (getf item :type))))
        (user (db userid))
        (reply
          (multiple-value-list
            (http-request
              (strcat *fb-graph-url*
                      "v2.5/me"
                      "/kindistadotorg:"
                      action-type)
              :parameters (list (cons "access_token" (getf user :fb-token))
                                (cons "method" "post")
                                (cons object-type
                                      (s+ "https://kindista.org"
                                          (resource-url id item)))
                                (cons "fb:explicitly_shared" "true"))))))

  (facebook-debugging-log reply (alist-plist (decode-json-octets (first reply))))
  (when (= (second reply) 200)
    (let ((data (alist-plist (decode-json-octets (first reply)))))
      (awhen (getf data :id) (safe-parse-integer it)))))

(defun get-facebook-object-id
  (k-id
   &aux (item (db k-id))
        (reply
          (multiple-value-list
             (http-request
               (strcat *fb-graph-url*)
               :parameters (list (cons "access_token" *facebook-app-token*)
                                 (cons "id" (s+ "https://kindista.org" (resource-url k-id item)))
                                 )))))

  (facebook-debugging-log reply (alist-plist (decode-json-octets (first reply))))
  (when (= (second reply) 200)
    ;; data and object are usefull for debugging
    (let* ((data (alist-plist (decode-json-octets (first reply))))
           (object (alist-plist (getf data :og--object))))
      (when object (safe-parse-integer (getf object :id))))))

(defun get-user-facebook-objects-of-type
  (typestring
   &optional (userid *userid*)
   &aux (user (db userid))
        (reply
          (multiple-value-list
            (with-facebook-credentials
              (http-request
                (strcat *fb-graph-url*
                        "me"
                       ;(or *fb-id* (getf user :fb-id))
                        "/kindistadotorg:post/"
                        typestring)
                :parameters (list (cons "access_token" (getf user :fb-token))
                                  (cons "method" "get")))))))

  (when (= (second reply) 200)
    (decode-json-octets (first reply))))

(defun fb-object-actions-by-user
  (k-item-id
   &key (data (db k-item-id))
        (userid *userid*)
        (fb-id (if (eql *userid* userid)
                 (getf *user* :fb-id)
                 (db userid :fb-id)))
   &aux (actions))
  (when userid
    (dolist (action (getf data :fb-actions))
      (when (eql (getf action :fb-id) fb-id)
        (push (getf action :fb-action-id) actions))))
  actions)

(defun update-facebook-object
  (k-id
   &aux (item (db k-id))
        (facebook-id (getf item :fb-object-id))
        (typestring (string-downcase (symbol-name (getf item :type))))
        (reply (with-facebook-credentials
                (multiple-value-list
                  (http-request
                    (strcat "https://graph.facebook.com/" facebook-id)
                    :parameters (list (cons "access_token"
                                            *facebook-app-token*)
                                      '("method" . "POST")
                                      (cons typestring
                                            (strcat "https://kindista.org"
                                                    (resource-url k-id item)))))))))
  "Works the same as (scrape-facebook-item)"
  (when (= (second reply) 200)
    (decode-json-octets (first reply))))

(defun scrape-facebook-item
  (url-or-fb-id
   &aux (reply  (multiple-value-list
                  (with-facebook-credentials
                    (http-request
                      "https://graph.facebook.com/"
                      :parameters (list (cons "id"
                                              (if (integerp url-or-fb-id)
                                                (write-to-string url-or-fb-id)
                                                url-or-fb-id))
                                         (cons "access_token"
                                               *facebook-app-token*)
                                        '("scrape" . "true"))
                      :method :post)))))

  "Works the same as (update-facebook-object)"
  (facebook-debugging-log url-or-fb-id reply (decode-json-octets (first reply)))
  (when (= (second reply) 200)
    (decode-json-octets (first reply))))

(defun get-facebook-action
  (k-id
   &optional (k-userid *userid*)
             (user (or *user* (db k-userid)))
   &aux (k-item (db k-id))
        (action-id (cdr (assoc (getf user :fb-id)
                               (getf k-item :fb-actions))))
        (reply (multiple-value-list
                 (with-facebook-credentials
                   (http-request
                     (strcat "https://graph.facebook.com/" action-id)
                     :parameters (list (cons "access_token"
                                             *facebook-app-token*)
                                       (cons "access_token"
                                             (getf user :fb-token))
                                       '("method" . "GET")))))))
 (values
   (decode-json-octets (first reply))
   (second reply)))

(defun delete-facebook-action
  (facebook-action-id
   &aux (reply (multiple-value-list
                 (with-facebook-credentials
                   (http-request
                     (strcat "https://graph.facebook.com/" facebook-action-id)
                     :parameters (list (cons "access_token"
                                             *facebook-app-token*)
                                       '("method" . "DELETE")))))))
 (values
   (decode-json-octets (first reply))
   (second reply)))

(defun get-taggable-fb-friends
  (&optional (userid *userid*)
             (user (if (eql userid *userid*) *user* (db userid)))
             (url (strcat *fb-graph-url*
                          "v2.6/"
                          (getf user :fb-id)
                          "/taggable_friends"))
   &aux (response))
  "Performs a call to the FB graph taggable_friends endpoint to get a list of all taggable friends."
  (when (active-facebook-user-p userid user)
    (setf response
          (multiple-value-list
            (http-request
              url
              :parameters (list (cons "access_token" *facebook-app-token*)
                                (cons "access_token" (getf user :fb-token))
                                (cons "limit" "5000")
                                (cons "method" "get"))))))
    (when (eql (second response) 200)
      (let ((results (decode-json-octets (first response))))
        results)))

(defun get-all-taggable-fb-friends
  (&optional (userid *userid*)
             (user (if (eql userid *userid*) *user* (db userid)))
   &aux (all-results)
        (current-results)
        (next)
        (requests 0))
  "Performs multiple calls to the FB graph taggable_friends endpoint to accumulate a list of all taggable friends. Not currently needed because that endpoint allows a 'limit' get parameter to get a list of all taggable friends."
  (labels ((request-loop ()
             (setf current-results
                   (apply #'get-taggable-fb-friends (remove nil (list userid user next))))
             (setf next (cdr (find :next
                                   (cdr (find :paging current-results :key 'car))
                                   :key 'car)))
             (incf requests)
             (if all-results
               (asetf all-results (append it (cdr (find :data current-results :key 'car))))
               (setf all-results (cdr (find :data current-results :key 'car))))
             ;; don't let it loop indefinitely
             (when (and (< requests 5)
                        (stringp next))
               (request-loop))))
    (request-loop))
  all-results)

(defun find-taggable-fb-friend-by-name (k-id name)
  (find name
        (get-all-taggable-fb-friends k-id)
        :key (lambda (item)
               (cdr (find :name item :key 'car)))
        :test #'string=))

(defun facebook-taggable-friend-tokens
  (k-user-ids-to-test
   &optional (userid *userid*)
   &aux (image-identifiers (mapcar (lambda (id)
                                     (cons id (facebook-image-identifyier id)))
                                   k-user-ids-to-test))
        (taggable-fb-friends (get-all-taggable-fb-friends userid))
        (taggable-k-users))
  "Returns and a-list of (k-userid . fb-taggable-token)"
  (flet ((get-pic-url-identifier (fb-data)
           (car
             (split "\\?"
               (car
                 (last
                   (url-parts
                     (cdr (find :url
                                (cdr (find :data
                                           (cdr (find :picture fb-data :key 'car))
                                           :key 'car))
                                :key 'car)))))))))
   (dolist (pair image-identifiers)
    (awhen (find (cdr pair)
                 taggable-fb-friends
                 :key #'get-pic-url-identifier
                 :test #'string=)
      (push (cons (car pair) (getf (alist-plist it) :id))
            taggable-k-users))))
  taggable-k-users)

(defun facebook-friends-permission-html
  (&key redirect-uri
        fb-gratitude-subjects
        (cancel-link "home")
        re-request
        (page-title "Tag your Facebook friends"))
  (standard-page
    page-title
    (html
      (:div :id "tag-fb-friends-auth"
       (:p :class "large"
         "Would you like to tag "
         (:strong (str (name-list-all fb-gratitude-subjects :stringp t
                                                            :conjunction :or)))
         " in the gratitude you published to Facebook?")
       (:p :class "small"
         "To enable tagging, Facebook requires that you give Kindista access to your Facebook friends list. We respect your privacy and your relationships; we will not spam your friends.")
       (str (facebook-sign-in-button :redirect-uri redirect-uri
                                     :scope "user_friends"
                                     :state "user_friends_scope_granted"
                                     :re-request re-request
                                     :button-text "Allow Kindista to see my list of Facebook friends"))
       (:a :href cancel-link :class "gray-text cancel" "Not now")))
    :selected "people"))

(defun tag-facebook-friends-html
  (&key gratitude-id
        fb-gratitude-subjects
        (page-title "Tag your Facebook friends")
   &aux (gratitude (when gratitude-id (db gratitude-id)))
        (fb-g-subject-ids (mapcar #'cdr fb-gratitude-subjects)))
  (awhen (set-difference (getf gratitude :subjects) fb-g-subject-ids)
    (flash (s+ (name-list it :links nil :maximum-links 10)
               " cannot be tagged. Either they have not linked their Facebook"
               " accounts with Kindista or they have not given permission"
               " for Kindista to see if you are friends on Facebook.")))
  (standard-page
    page-title
    (html
      (:div :id "tag-fb-friends"
       (:h3 "You have published this Statement of Gratitude on your Facebook feed:")
       (:blockquote
         (str (gratitude-activity-item (gethash gratitude-id *db-results*)
                                       :show-actions nil)))

       (:form :method "post" :action (strcat "/gratitude/" gratitude-id)
         (:fieldset
           (:legend (str page-title))
           (dolist (pair fb-gratitude-subjects)
             (htm
               (:div :class "friend-to-tag"
                  (:div :class "g-recipient item"
                    (:input :type "checkbox"
                            :name "tag-fb-friend"
                            :value (cdr pair)
                            :id (cdr pair)
                            :checked "")
                    (:label :for (cdr pair)
                     (:img :src (get-avatar-thumbnail (cdr pair) 70 70))
                     (str (car pair))))))))
         (:p (:button :class "cancel" :type "submit" :class "cancel" :name "cancel" "Cancel")
             (:button :class "yes" :type "submit" :class "submit" :name "tag-friends" "Tag Friends")))))
    :selected "people"))

(defun tag-facebook-friends
  (k-item-id
   k-contacts-to-tag-on-fb
   &optional (userid *userid*)
   &aux (item (db k-item-id))
        (user (if (eql userid *userid*) *user* (db userid)))
        (response)
        (taggable-friend-tokens (facebook-taggable-friend-tokens
                                  k-contacts-to-tag-on-fb
                                  userid))
        ;; taggable-friend-tokens is an a-list of (k-userid . fb-taggable-token)
        (friends-to-tag (separate-with-commas
                          (remove nil (mapcar (lambda (id)
                                                (cdr (assoc id taggable-friend-tokens)))
                                              k-contacts-to-tag-on-fb))
                          :omit-spaces t))
        (action-id (first (fb-object-actions-by-user k-item-id
                                                     :data item
                                                     :userid userid
                                                     :fb-id (getf user :fb-id)))))
  ;; Tagging is convoluted until Facebook changes it's API to allow apps to pass
  ;; FB user ids to tag an item. Now we have to associate taggable-tokens with known profile
  ;; pic urls associated with fb-ids.
  (when (active-facebook-user-p userid user)
    (setf response
          (multiple-value-list
            (http-request
              (strcat *fb-graph-url*
                      "v2.6/"
                      action-id)
              :parameters (list (cons "access_token" (getf user :fb-token))
                                (cons "tags" friends-to-tag))
              :method :post)))
    (setf response (decode-json-octets (first response)))
    (facebook-debugging-log action-id k-contacts-to-tag-on-fb taggable-friend-tokens friends-to-tag response)
    response))

(defun post-uninstall-facebook
  (&aux (signed-request (post-parameter "signed_request"))
        (split-request (split "\\." signed-request))
        (signature (substitute #\+ #\- (substitute #\/ #\_ (first split-request))))
        (expected-sig)
        (raw-data (second split-request))
        (hmac (ironclad:make-hmac (string-to-octets *facebook-secret*) :sha256))
        (json)
        (fb-id)
        (userid))

  (ironclad:update-hmac hmac (string-to-octets raw-data))
  (setf expected-sig
        (remove #\= (base64:usb8-array-to-base64-string
                      (ironclad:hmac-digest hmac))))
  (if (equalp expected-sig signature)
    (progn
      (setf json
            (json:decode-json-from-string
              (with-output-to-string (s)
                (base64:base64-string-to-stream raw-data :uri t :stream s))))
      (setf fb-id (safe-parse-integer (getf json :user-id)))
      (setf userid (gethash fb-id *facebook-id-index*))
      (modify-db userid :fb-link-active nil)
      (with-locked-hash-table (*facebook-id-index*)
        (remhash fb-id *facebook-id-index*))
      (setf (return-code*) +http-no-content+)
      nil)
    (progn (setf (return-code*) +http-forbidden+)
           nil)))
