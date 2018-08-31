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

;bug list
;fix top tag display
 
(defun offers-help-text ()
  (welcome-bar
    (html
      (:h2 "Getting started with offers")
      (:p "Here are some things you can do to get started:")
      (:ul
        (:li (:a :href "/offers/new" "Post an offer") " you have that someone else in the community might be able to use.")
        (:li "Browse recently posted offers listed below.")
        (:li "Find specific offers by selecting keywords from the " (:strong "browse by keyword") " menu.")
        (:li "Search for offers using the search "
          (:span :class "menu-button" "button")
          (:span :class "menu-showing" "bar")
          " at the top of the screen.")))))

(defun get-offers-new ()
  (require-user (:allow-test-user t :require-email t)
    (enter-inventory-item-details :page-title "Post an offer"
                                  :action "/offers/new"
                                  :button-text "Post offer"
                                  :selected "offers")))

(defun post-offers-new ()
  (post-new-inventory-item "offer" :url "/offers/new"))

(defun get-offer (id)
  (unless (integerp id)
    (setf id (parse-integer id)))
  (let* ((offer (db id))
         (by (getf offer :by))
         (self (eql *userid* by))
         (result (gethash id *db-results*))
         ;; now using publish-facebook-action to get action-id
        ;(fb-action-id (when (string= (referer)
        ;                             "https://www.facebook.com/")
        ;                (get-parameter-integer "post_id")))
         (action-type (get-parameter-string "action-type"))
         (group-admin-p (group-admin-p by *userid*))
         (matching-requests (gethash id *offers-with-matching-requests-index*)))

    (cond
      ((or (not offer)
           (not (eql (getf offer :type) :offer)))
       (not-found))

     ((and (getf offer :violates-terms)
           (not self)
           (not (getf *user* :admin)))
        (item-violates-terms))

     ((and (not self)
           (item-view-denied (result-privacy result)))
       (permission-denied))

     (action-type
      (register-inventory-item-action id
                                      action-type
                                      :item offer
                                      :reply t))

     ((and self (get-parameter "deactivate"))
      (post-existing-inventory-item "offer"
                                    :id id
                                    :deactivate t
                                    :url (script-name*)))

     ((and (or self group-admin-p) (get-parameter "edit"))
      (post-existing-inventory-item "offer"
                                    :id id
                                    :edit t
                                    :url (script-name*)))

     (t
      (with-location
        (standard-page
          "Offers"
          (html
            (:div :class  "inventory-item-page"
              (unless (getf offer :active)
                (htm
                  (:h2 :class "red" "This offer is no longer active.")))
              (str (inventory-activity-item result
                                            :show-icon t
                                            :show-recent-action t
                                            :show-distance t
                                            :show-tags t)))
            (str (item-images-html id))
            (when (and (or self group-admin-p)
                       matching-requests)
              (str (item-matches-html id :data offer
                                         :current-matches matching-requests))))
          :extra-head (facebook-item-meta-content
                        id
                        "offer"
                        (strcat* "Kindista Offer: " (getf offer :title))
                        :image (awhen (first (getf offer :images))
                                 (get-image-thumbnail it 1200 1200)))
          :extra-fb-js (when (and (eql (getf offer :by)
                                  *userid*)
                                  (getf offer :fb-publishing-in-process)
                                  (< (- (get-universal-time)
                                        (getf offer :fb-publishing-in-process))
                                     30000))
                         *fb-share-dialog-on-page-load*)
          :selected "offers"))))))

(defun get-offer-reply (id)
  (require-user ()
    (let* ((id (parse-integer id))
           (data (db id)))
      (if (eql (getf data :type) :offer)
        (inventory-item-reply "offer" id data)
        (not-found)))))

(defun post-offer (id)
  (post-existing-inventory-item "offer" :id id :url (script-name*)))

(defun get-offers ()
  (with-user
    (when *userid*
      (send-metric* :got-offers *userid*))
    (with-location
      (let* ((page (if (scan +number-scanner+ (get-parameter "p"))
                     (parse-integer (get-parameter "p"))
                     0))
             (q (get-parameter "q"))
             (base (iter (for tag in (split " " (get-parameter "kw")))
                         (when (scan *tag-scanner* tag)
                           (collect tag))))
             (start (* page 20)))
        (when (string= q "") (setf q nil))
        (multiple-value-bind (tags items)
          (nearby-inventory-top-tags :offer :base base :q q)
          (standard-page
           "Offers"
           (inventory-body-html "an"
                                "offer"
                                :base base
                                :q q
                                :items items
                                :start start
                                :page page)
          :top (when (getf *user* :help)
                 (offers-help-text))
          :search q
          :search-scope (if q "offers" "all")
          :right (browse-inventory-tags "offer" :q q :base base :tags tags)
          :selected "offers"))))))


(defun get-offers-all ()
  (with-user
    (with-location
      (let ((base (iter (for tag in (split " " (get-parameter "kw")))
                        (when (scan *tag-scanner* tag)
                          (collect tag)))))
        (multiple-value-bind (tags items)
            (nearby-inventory-top-tags :offer :count 10000 :subtag-count 10)
          (declare (ignore items))
          (standard-page
           "offers"
             (browse-all-inventory-tags "an" "offer" :base base :tags tags)
             :top (when (getf *user* :help)
                   (offers-help-text))
             :selected "offers"))))))
