# entrypoint.sh pipes nginx's error log (stderr) through this script, with
# GNU sed -u -E, before it leaves the container. nginx error messages quote
# the request line, the upstream URL and the Referer, query strings included,
# and nginx cannot change that format. Remove every query string and replace
# credential-shaped tokens (sk-, adm_, sess_, JWT) with [redacted]; the rest
# of the line is kept (tests/test-admin-audit-log.sh).
s/\?[^" ]*//g
s/(^|[^A-Za-z0-9]|%[0-9A-Fa-f]{2})(sk-[A-Za-z0-9]{16}|adm_[A-Za-z0-9_-]{16}|sess_[A-Za-z0-9_-]{16})[A-Za-z0-9_-]*/\1[redacted]/g
s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]*/[redacted]/g
