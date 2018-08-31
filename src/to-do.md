## subscribe users and group admins to :notify-inventory-expiration
## post offers/requests to facebook
## split up database
  - if we create different directories for datatypes, make sure to get a comprehensive list of all datatypes in the database (including "deleted" types)
## accountability with user flaky-ness
  - possible survey in transaction items to provide feedback re: experience
    with the other party
  - timeliness, enjoyment of interaction, etc.
  - ability to see constructive feedback if others can see yours
## better matching of search results
## group discussions
## email preferences for deactivated accounts
  - check gratitude emails sent to people with (db id :active nil)
  - if they want to be notified when gratitudes are posted to their account
    let them know that they won't be shown on their profile until they
    reactivate? (if this is so, then email should remind of this detail)
## enable gratitude recipients to hide gratitudes
## allow people to offer or request items anonymously
## add gratitude option for standard invitations
## allow kindista offers tagged with "proposed-feature" to get a tab in the feedback section
  - create an email that requests feedback on proposed feedback from current users with (eq (getf *user* :notify-kindista) t)
## invite facebook friends
## invite gmail/hotmail/yahoo contacts
## flag items
## reply by email (maybe)
