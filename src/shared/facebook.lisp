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

(defmacro with-facebook-credentials (&body body)
  `(let ((*facebook-app-token* (or *facebook-app-token*
                                   (setf *facebook-app-token*
                                         (get-facebook-app-token))))
         (*fb-id* (getf *user* :fb-id))
         (*facebook-user-token* (getf *user* :fb-token))
         (*facebook-user-token-expiration* (getf *user* :fb-expires)))
     ,@body))

(defun facebook-item-meta-content
  (id
   typestring
   title
   &key description
        determiner
        image)
  (html
    (:meta :property "og:type"
           :content (s+ "kindistadotorg:" typestring))
    (awhen determiner
      (htm (:meta :property "og:determiner" :content it)))
    (:meta :property "fb:app_id"
           :content *facebook-app-id*)
    (:meta :property "og:url"
           :content (strcat* +base-url+
                             typestring
                             (when (or (string= typestring "offer")
                                       (string= typestring "request"))
                               "s")
                             "/"
                             id))
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
                               "redirect_uri" (url-encode
                                                (s+ +base-url+ redirect-uri)))
                         (when state
                           (list "state" state)))))
        (str button-text))))

(defun facebook-debugging-log (&rest messages)
  (with-open-file (s (s+ +db-path+ "/tmp/log") :direction :output :if-exists :append)
    (setf *print-readably* nil)
    (format s "~{~S~%~}" messages)))

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

(defun get-facebook-profile-picture
  (k-user-id
   &aux (user (db k-user-id))
        (fb-token (getf user :fb-token))
        (fb-user-id (getf user :fb-id))
        (response)
        (image-id))
  (when (and fb-token fb-user-id)
   (setf response
         (multiple-value-list
           (http-request (strcat *fb-graph-url* "v2.5/" fb-user-id "/picture")
                         :parameters (list (cons "access_token" fb-token)
                                           (cons "type" "large")
                                           (cons "method" "get")))))
   (when (eql (second response) 200)
      (setf image-id
            (create-image (first response)
                          (cdr (assoc :content-type (third response)))))))
  image-id)

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

    (setf current-permissions
          (mapcar
            (lambda (pair)
              (when (string= (cdr pair) "granted")
                (make-keyword
                  (string-upcase (substitute #\- #\_ (car pair))))))
            (loop for permission in (getf (alist-plist
                                            (decode-json-octets
                                              (first response)))
                                          :data)
                  collect (cons (cdar permission) (cdadr permission)))))
    current-permissions)

(defun check-facebook-permission
  (permission
   &optional (userid *userid*)
   &aux (user (db userid))
        (saved-fb-permissions (getf user :fb-permissions))
        (current-fb-permissions (get-facebook-user-permissions userid user)))
  (when (set-exclusive-or saved-fb-permissions current-fb-permissions)
    (modify-db userid :fb-permissions current-fb-permissions))
  (find permission current-fb-permissions))

(defun get-facebook-kindista-friends
  (k-id
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
  (decode-json-octets (first response))
  )

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
  (&aux (data (notice-data))
        (userid (getf data :userid))
        (item-id (getf data :item-id))
        (fb-action-id)
        (fb-object-id))
  (facebook-debugging-log data)

  ;; userid is included w/ new publish request but not scraping new data
  (facebook-debugging-log userid)
  (when userid
    (setf fb-action-id
          (publish-facebook-action item-id userid))
    (setf fb-object-id (get-facebook-object-id item-id)))
  (cond
    (userid
      ;; update kindista DB with new facebook object/action ids
      (http-request
        (s+ +base-url+ "publish-facebook")
        :parameters (list (cons "item-id" (strcat item-id))
                          (cons "fb-action-id" (strcat fb-action-id))
                          (cons "fb-object-id" (strcat fb-object-id)))
        :method :post))
    ((getf data :object-modified)
      (scrape-facebook-item (getf data :fb-object-id)))))

(defun post-new-facebook-data
  (&aux (item-id (post-parameter-integer "item-id"))
        (fb-action-id (post-parameter-integer "fb-action-id"))
        (fb-object-id (post-parameter-integer "fb-object-id")))
  (if (server-side-request-p)
    (progn
      (modify-db item-id :fb-action-id fb-action-id
                         :fb-object-id fb-object-id)
      (setf (return-code*) +http-no-content+)
      nil)
    (progn
      (setf (return-code*) +http-forbidden+)
      nil)))

(defun publish-facebook-action
  (id
   &optional (userid *userid*)
   &aux (item (db id))
        (action-type (case (getf item :type)
                       (:gratitude "express")
                       (t "post")))
        (object-type (string-downcase (symbol-name (getf item :type))))
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
                                (cons "fb:explicitly_shared" "true")
                                (cons "privacy"
                                       (json:encode-json-to-string
                                         (list (cons "value" "SELF")))))))))

  (facebook-debugging-log (decode-json-octets (first reply))
                          (second reply)
                          (third reply))
  (when (= (second reply) 200)
    (let ((data (alist-plist (decode-json-octets (first reply)))))
      (facebook-debugging-log data)
      (parse-integer (getf data :id)))))

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

  (when (= (second reply) 200)
    ;; data and object are usefull for debugging
    (let* ((data (alist-plist (decode-json-octets (first reply))))
           (object (alist-plist (getf data :og--object))))
      (parse-integer (getf object :id)))))

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
  (facebook-debugging-log reply (second reply) (decode-json-octets (first reply)))
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
  (when (= (second reply) 200)
    (decode-json-octets (first reply))))

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

(defun get-facebook-app-token ()
    (string-left-trim "access_token="
      (http-request
        (url-compose "https://graph.facebook.com/oauth/access_token"
                     "client_id" *facebook-app-id*
                     "client_secret" *facebook-secret*
                     "grant_type" "client_credentials"))))

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

(defun facebook-friends-permission-html
  (&key gratitude-id
        redirect-uri
        fb-gratitude-subjects
        (page-title "Tag your Facebook friends"))
  (standard-page
    page-title
    (html
      (:div :id "tag-fb-friends-auth"
       (:h2 (str page-title))
       (:p
         (:strong (str (name-list-all fb-gratitude-subjects :stringp t)))
         (str (if (> (length fb-gratitude-subjects) 1) " have " " has "))
         " their Facebook account linked to Kindista.")
       (:h3 "Would you like to tag them in the gratitude you published to Facebook?")
       (:p "To enable tagging, Facebook requires that you give Kindista access to your Facebook friends list. We respect your privacy and your relationships; we will not spam your friends.")
       (str (facebook-sign-in-button :redirect-uri redirect-uri
                                     :scope "user_friends"
                                     :state "tag_friends"
                                     :button-text "Allow Kindista to see my list of Facebook friends"))))
    :selected "people"
    ))

(defun tag-facebook-friends-html
  (&key gratitude-id
        fb-gratitude-subjects
        (page-title "Tag your Facebook friends"))
  (standard-page
    page-title
    (html
      (:div :id "tag-fb-friends-auth"
       (:h2 (str page-title))
       (:form :method "post" :action (strcat "gratitude/" gratitude-id)
         (:fieldset
           (dolist (pair fb-gratitude-subjects)
           (htm
             (:div :class "g-recipient"
              (:input :type "checkbox"
                      :name "tag-friend"
                      :value (cdr pair)
                      :id (cdr pair)
                      :checked "")
              (:label :for (cdr pair) (str (car pair)))))))
         (:p (:button :class "cancel" :type "submit" :class "cancel" :name "cancel" "Cancel")
             (:button :class "yes" :type "submit" :class "submit" :name "tag-friends" "Tag Friends")))))
    :selected "people"
    ))
