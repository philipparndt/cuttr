## MODIFIED Requirements

### Requirement: A browser is found, not bundled

cuttr SHALL look for Chrome, then Chromium, then Edge, and SHALL name what to
install when it finds none. A browser SHALL NOT be downloaded or bundled.

cuttr SHALL open it the same way it opens a terminal — as an application, so
that one mechanism starts, sizes, finds the window of, and closes every one of
them. Starting a browser as a subprocess worked and starting Ghostty that way
does not, and two ways of opening an application is one more than is worth
maintaining.

#### Scenario: Nothing to drive
- **WHEN** no supported browser is installed
- **THEN** recording refuses with a sentence naming the browsers it looks for,
  and nothing is written

#### Scenario: A fresh instance, not the one that is open
- **WHEN** a recording is made while the person's own Chrome is running
- **THEN** cuttr opens a separate instance with its own profile, and closing it
  afterwards leaves the person's windows alone
