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

(defun facebook-item-meta-content (id typestring title &optional description)
  (html
    (:meta :property "og:type"
           :content (s+ "kindistadotorg:" typestring))
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
                  :content (escape-for-html it))))))

(defun facebook-sign-in-button
  (&key (redirect-uri "home")
        (button-text "Sign in with Facebook")
        scope)
  (asetf scope
         (strcat* (if (listp scope)
                    (format nil "~{~A,~}" scope)
                    (s+ scope ","))
                  "public_profile,publish_actions,email"))
  (html
    (:a :class "blue"
        :href (url-compose "https://www.facebook.com/dialog/oauth"
                           "client_id" *facebook-app-id*
                           "scope" scope
                           "redirect_uri" (url-encode (s+ +base-url+ redirect-uri)))
        (str button-text))))

(defun facebook-debugging-log (message)
  (with-open-file (s (s+ +db-path+ "/tmp/log") :direction :output :if-exists :append)
    (format s "~S~%" message)))

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
  (&key (userid *userid*)
        fb-token
        &aux (*user* (or *user* (db userid)))
        reply)

  (setf reply
        (multiple-value-list
          (with-facebook-credentials
            (http-request
              (s+ *fb-graph-url* "debug_token")
              :parameters (list (cons "input_token"
                                      (or fb-token *facebook-user-token*))
                                (cons "access_token" *facebook-app-token*))))))

  (when (= (second reply) 200)
    (cdr (find :data
               (decode-json-octets (first reply))
               :key #'car))))

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

(defun get-facebook-location-data (fb-location-id fb-token)
  (alist-plist
    (cdr
      (assoc :location
             (decode-json-octets
               (http-request (strcat *fb-graph-url*
                                     "v2.5/"
                                     fb-location-id)
                             :parameters (list (cons "access_token" fb-token)
                                               (cons "fields" "location")
                                               (cons "method" "get"))))))))

(defun new-facebook-action-notice-handler
  (&aux (data (notice-data)))
  (http-request (s+ +base-url+ "publish-facebook")
                :parameters (list (cons "item-id"
                                        (strcat (getf data :item-id)))
                                  (cons "userid"
                                        (strcat (getf data :userid)))
                                  (cons "action-type" (getf data :action-type)))
                :method :post))

(defun post-new-facebook-action
  (&aux (item-id (get-parameter-integer "item-id"))
        (userid (get-parameter-integer "userid"))
        (action-type (get-parameter-string "action-type"))
        (server-side-request-p (server-side-request-p)))
  (facebook-debugging-log (strcat "Server-side-p: " server-side-request-p))
  (if server-side-request-p
    (progn
      (modify-db item-id :fb-action-id (publish-facebook-action item-id
                                                                userid
                                                                action-type))
      (register-facebook-object-id item-id)
      (setf (return-code*) +http-no-content+))
    (setf (return-code*) +http-forbidden+)))

(defun publish-facebook-action
  (id
   &optional (userid *userid*)
             (action-type "post")
   &aux (item (db id))
        (object-type (string-downcase (symbol-name (getf item :type))))
        (user (db userid))
        (reply
          (multiple-value-list
            (with-facebook-credentials
              (http-request
                (strcat *fb-graph-url*
                        "me"
                       ;(or *fb-id* (getf user :fb-id))
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
                                           (list (cons "value" "SELF"))))))))))

  (facebook-debugging-log reply)
  (when (= (second reply) 200)
    (parse-integer (cdr (assoc :id
                               (decode-json-octets (first reply)))))))

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
    (parse-integer
      (getf (alist-plist (getf (alist-plist (decode-json-octets (first reply)))
                               :og--object))
            :id))))

(defun register-facebook-object-id (k-id)
  (modify-db k-id :fb-object-id (get-facebook-object-id k-id)))

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
        (facebook-id (getf item :fb-id))
        (typestring (string-downcase (symbol-name (getf item :type))))
        (reply (with-facebook-credentials
                (multiple-value-list
                  (http-request
                    (strcat "https://graph.facebook.com/" facebook-id)
                    :parameters (list (cons "access_token"
                                            *facebook-app-token*)
                                      '("method" . "POST")
                                      (cons typestring
                                            (url-compose
                                              (strcat "https://kindista.org/"
                                                      typestring
                                                      "s/"
                                                      k-id)))))))))
  "Works the same as (scrape-facebook-item)"
  (when (= (second reply) 200)
    (decode-json-octets (first reply))
   ))

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
      (setf (return-code*) +http-no-content+))
    (setf (return-code*) +http-forbidden+)))
