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
  (require-user
    (enter-inventory-text :title "Post an offer"
                          :action "/offers/new"
                          :selected "offers")))
(defun post-offers-new ()
  (post-new-inventory-item "offer" :url "/offers/new"))

(defun get-offer (id)
  (setf id (parse-integer id))
  (aif (db id)
    (with-location
      (standard-page
        "Offers"
        (html
          (:div :class "activity item"
            (str (inventory-activity-item "offer" (gethash id *db-results*) :show-distance t)))
          (str (item-images-html id)))
        :selected "offers"))
    (not-found)))

(defun get-offer-edit (id)
  (require-user
    (let* ((offer (db (parse-integer id))))
      (require-test ((or (eql *userid* (getf offer :by))
                         (getf *user* :admin))
                   "You can only edit offers you have posted.")
        (enter-inventory-tags :title "Edit your offer"
                              :action (s+ "/offers/" id "/edit")
                              :text (getf offer :text)
                              :tags (getf offer :tags)
                              :button-text "Save offer"
                              :selected "offers")))))

(defun get-offer-reply (id)
  (require-user
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
           (inventory-body-html "offer" :base base
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
