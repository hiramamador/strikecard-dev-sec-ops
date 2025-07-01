##gatetway server
-apache
-gunicorn for small scripts
-prometheus, grafana
-fail2ban (or similar)
-ssh access from the world
##application server
-django running through gunicorn
-redis
-ssh access from gateway
##database server
-postgres
-ssh access from gateway