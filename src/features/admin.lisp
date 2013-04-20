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

(defmacro require-admin (&body body)
  `(with-user
     (if (getf *user* :admin)
       (progn ,@body)
       (not-found))))

(defun get-admin ()
  (require-admin
    (standard-page
      "Admin"
      (html
        (:h1 "Admin")
        (:ul
          (:li (:a :href "/admin/old-inventory" "old inventory items"))
          (:li (:a :href "/admin/recent" "recently added"))))
      :selected "admin")))

(defun get-admin-old-inventory ()
  (require-admin
    (standard-page
      "Recently Added"
      (html
        (:p (:a :href "/admin" "back to admin"))
        (:h1 "old inventory items")
        (let ((page (if (scan +number-scanner+ (get-parameter "p"))
                     (parse-integer (get-parameter "p"))
                     0)))
         (with-location
           (str (activity-items *old-inventory-index* :url "/admin/old-inventory" :page page)))))
      :selected "admin")))

(defun get-admin-recent ()
  (require-admin
    (standard-page
      "Recently Added"
      (html
        (:p (:a :href "/admin" "back to admin"))
        (:h1 "recent sitewide activity")
        (let ((page (if (scan +number-scanner+ (get-parameter "p"))
                     (parse-integer (get-parameter "p"))
                     0)))
          (with-location
            (str (activity-items (sort (copy-list *recent-activity-index*) #'> :key #'result-time)
                                 :url "/admin/recent"
                                 :page page)))))
      :selected "admin")))
