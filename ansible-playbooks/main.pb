---
# Main playbook for three-server infrastructure
- name: Setup Gateway Server
  hosts: gateway
  become: yes
  vars:
    fail2ban_services:
      - ssh
      - apache
      - apache-auth
  
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install base packages
      apt:
        name:
          - apache2
          - python3
          - python3-pip
          - python3-venv
          - fail2ban
          - ufw
          - htop
          - curl
          - wget
          - git
        state: present

    - name: Install Python packages for Gunicorn
      pip:
        name:
          - gunicorn
          - flask
        executable: pip3

    - name: Create application directory
      file:
        path: /opt/scripts
        state: directory
        owner: www-data
        group: www-data
        mode: '0755'

    - name: Create simple Flask app for testing
      copy:
        content: |
          from flask import Flask
          app = Flask(__name__)
          
          @app.route('/')
          def hello():
              return 'Gateway Scripts Server Running!'
          
          if __name__ == '__main__':
              app.run()
        dest: /opt/scripts/app.py
        owner: www-data
        group: www-data
        mode: '0644'

    - name: Create Gunicorn systemd service
      copy:
        content: |
          [Unit]
          Description=Gunicorn instance to serve scripts
          After=network.target

          [Service]
          User=www-data
          Group=www-data
          WorkingDirectory=/opt/scripts
          Environment="PATH=/opt/scripts/venv/bin"
          ExecStart=/usr/local/bin/gunicorn --workers 3 --bind unix:app.sock -m 007 app:app
          ExecReload=/bin/kill -s HUP $MAINPID
          Restart=always

          [Install]
          WantedBy=multi-user.target
        dest: /etc/systemd/system/gunicorn-scripts.service
        mode: '0644'

    - name: Enable and start Gunicorn service
      systemd:
        name: gunicorn-scripts
        enabled: yes
        state: started
        daemon_reload: yes

    - name: Configure Apache virtual host
      copy:
        content: |
          <VirtualHost *:80>
              ServerName {{ ansible_default_ipv4.address }}
              DocumentRoot /var/www/html
              
              ProxyPreserveHost On
              ProxyPass /scripts/ unix:/opt/scripts/app.sock|http://localhost/
              ProxyPassReverse /scripts/ unix:/opt/scripts/app.sock|http://localhost/
              
              ErrorLog ${APACHE_LOG_DIR}/error.log
              CustomLog ${APACHE_LOG_DIR}/access.log combined
          </VirtualHost>
        dest: /etc/apache2/sites-available/000-default.conf

    - name: Enable Apache modules
      apache2_module:
        name: "{{ item }}"
        state: present
      loop:
        - proxy
        - proxy_http
      notify: restart apache2

    - name: Install Prometheus
      shell: |
        cd /tmp
        wget https://github.com/prometheus/prometheus/releases/download/v2.47.0/prometheus-2.47.0.linux-amd64.tar.gz
        tar xzf prometheus-2.47.0.linux-amd64.tar.gz
        cp prometheus-2.47.0.linux-amd64/prometheus /usr/local/bin/
        cp prometheus-2.47.0.linux-amd64/promtool /usr/local/bin/
        mkdir -p /etc/prometheus /var/lib/prometheus
        cp -r prometheus-2.47.0.linux-amd64/consoles /etc/prometheus/
        cp -r prometheus-2.47.0.linux-amd64/console_libraries /etc/prometheus/
        chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
      args:
        creates: /usr/local/bin/prometheus

    - name: Create prometheus user
      user:
        name: prometheus
        system: yes
        shell: /bin/false
        home: /var/lib/prometheus

    - name: Create Prometheus configuration
      copy:
        content: |
          global:
            scrape_interval: 15s
            evaluation_interval: 15s

          scrape_configs:
            - job_name: 'prometheus'
              static_configs:
                - targets: ['localhost:9090']
            
            - job_name: 'gateway'
              static_configs:
                - targets: ['localhost:9100']
            
            - job_name: 'application'
              static_configs:
                - targets: ['{{ hostvars[groups["application"][0]]["ansible_default_ipv4"]["address"] }}:9100']
            
            - job_name: 'database'
              static_configs:
                - targets: ['{{ hostvars[groups["database"][0]]["ansible_default_ipv4"]["address"] }}:9100']
        dest: /etc/prometheus/prometheus.yml
        owner: prometheus
        group: prometheus

    - name: Create Prometheus systemd service
      copy:
        content: |
          [Unit]
          Description=Prometheus
          Wants=network-online.target
          After=network-online.target

          [Service]
          User=prometheus
          Group=prometheus
          Type=simple
          ExecStart=/usr/local/bin/prometheus \
            --config.file /etc/prometheus/prometheus.yml \
            --storage.tsdb.path /var/lib/prometheus/ \
            --web.console.templates=/etc/prometheus/consoles \
            --web.console.libraries=/etc/prometheus/console_libraries \
            --web.listen-address=0.0.0.0:9090

          [Install]
          WantedBy=multi-user.target
        dest: /etc/systemd/system/prometheus.service

    - name: Install Grafana
      shell: |
        wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
        echo "deb https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
        apt update
        apt install -y grafana
      args:
        creates: /usr/sbin/grafana-server

    - name: Configure Fail2ban
      copy:
        content: |
          [DEFAULT]
          bantime = 3600
          findtime = 600
          maxretry = 5
          backend = systemd

          [sshd]
          enabled = true
          port = ssh
          logpath = %(sshd_log)s

          [apache-auth]
          enabled = true
          port = http,https
          logpath = %(apache_error_log)s

          [apache-badbots]
          enabled = true
          port = http,https
          logpath = %(apache_access_log)s
          bantime = 48h
          maxretry = 1
        dest: /etc/fail2ban/jail.local

    - name: Configure UFW - Allow SSH from anywhere
      ufw:
        rule: allow
        port: '22'
        proto: tcp

    - name: Configure UFW - Allow HTTP
      ufw:
        rule: allow
        port: '80'
        proto: tcp

    - name: Configure UFW - Allow HTTPS
      ufw:
        rule: allow
        port: '443'
        proto: tcp

    - name: Configure UFW - Allow Prometheus
      ufw:
        rule: allow
        port: '9090'
        proto: tcp

    - name: Configure UFW - Allow Grafana
      ufw:
        rule: allow
        port: '3000'
        proto: tcp

    - name: Enable UFW
      ufw:
        state: enabled

    - name: Start and enable services
      systemd:
        name: "{{ item }}"
        enabled: yes
        state: started
        daemon_reload: yes
      loop:
        - apache2
        - prometheus
        - grafana-server
        - fail2ban

  handlers:
    - name: restart apache2
      systemd:
        name: apache2
        state: restarted

---
- name: Setup Application Server
  hosts: application
  become: yes
  vars:
    django_project: myproject
    django_user: django
    
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install base packages
      apt:
        name:
          - python3
          - python3-pip
          - python3-venv
          - python3-dev
          - build-essential
          - redis-server
          - nginx
          - ufw
          - htop
          - curl
          - wget
          - supervisor
        state: present

    - name: Create django user
      user:
        name: "{{ django_user }}"
        system: yes
        shell: /bin/bash
        home: "/home/{{ django_user }}"
        create_home: yes

    - name: Create Django project directory
      file:
        path: "/home/{{ django_user }}/{{ django_project }}"
        state: directory
        owner: "{{ django_user }}"
        group: "{{ django_user }}"
        mode: '0755'

    - name: Create Python virtual environment
      shell: python3 -m venv venv
      args:
        chdir: "/home/{{ django_user }}/{{ django_project }}"
        creates: "/home/{{ django_user }}/{{ django_project }}/venv"
      become_user: "{{ django_user }}"

    - name: Install Django and Gunicorn in venv
      pip:
        name:
          - django
          - gunicorn
          - redis
          - psycopg2-binary
        virtualenv: "/home/{{ django_user }}/{{ django_project }}/venv"
      become_user: "{{ django_user }}"

    - name: Create Django project
      shell: |
        source venv/bin/activate
        django-admin startproject {{ django_project }} .
      args:
        chdir: "/home/{{ django_user }}/{{ django_project }}"
        creates: "/home/{{ django_user }}/{{ django_project }}/manage.py"
      become_user: "{{ django_user }}"

    - name: Configure Django settings
      lineinfile:
        path: "/home/{{ django_user }}/{{ django_project }}/{{ django_project }}/settings.py"
        regexp: "ALLOWED_HOSTS = \\[\\]"
        line: "ALLOWED_HOSTS = ['{{ hostvars[groups['gateway'][0]]['ansible_default_ipv4']['address'] }}', '{{ ansible_default_ipv4.address }}', 'localhost']"
      become_user: "{{ django_user }}"

    - name: Create Gunicorn configuration
      copy:
        content: |
          bind = "unix:/home/{{ django_user }}/{{ django_project }}/gunicorn.sock"
          workers = 3
          user = "{{ django_user }}"
          group = "{{ django_user }}"
          chdir = "/home/{{ django_user }}/{{ django_project }}"
          django_settings_module = "{{ django_project }}.settings"
          pythonpath = "/home/{{ django_user }}/{{ django_project }}"
        dest: "/home/{{ django_user }}/{{ django_project }}/gunicorn.conf.py"
        owner: "{{ django_user }}"
        group: "{{ django_user }}"

    - name: Create Supervisor configuration for Django
      copy:
        content: |
          [program:django]
          command=/home/{{ django_user }}/{{ django_project }}/venv/bin/gunicorn {{ django_project }}.wsgi:application -c /home/{{ django_user }}/{{ django_project }}/gunicorn.conf.py
          directory=/home/{{ django_user }}/{{ django_project }}
          user={{ django_user }}
          autostart=true
          autorestart=true
          redirect_stderr=true
          stdout_logfile=/var/log/django.log
        dest: /etc/supervisor/conf.d/django.conf

    - name: Configure Redis
      lineinfile:
        path: /etc/redis/redis.conf
        regexp: '^bind 127.0.0.1'
        line: 'bind 127.0.0.1 {{ ansible_default_ipv4.address }}'

    - name: Configure UFW - Deny all incoming by default
      ufw:
        default: deny
        direction: incoming

    - name: Configure UFW - Allow SSH from gateway only
      ufw:
        rule: allow
        port: '22'
        proto: tcp
        src: "{{ hostvars[groups['gateway'][0]]['ansible_default_ipv4']['address'] }}"

    - name: Configure UFW - Allow Django from gateway
      ufw:
        rule: allow
        port: '8000'
        proto: tcp
        src: "{{ hostvars[groups['gateway'][0]]['ansible_default_ipv4']['address'] }}"

    - name: Configure UFW - Allow Redis from gateway
      ufw:
        rule: allow
        port: '6379'
        proto: tcp
        src: "{{ hostvars[groups['gateway'][0]]['ansible_default_ipv4']['address'] }}"

    - name: Enable UFW
      ufw:
        state: enabled

    - name: Start and enable services
      systemd:
        name: "{{ item }}"
        enabled: yes
        state: started
      loop:
        - redis-server
        - supervisor

    - name: Update supervisor and start Django
      shell: |
        supervisorctl reread
        supervisorctl update
        supervisorctl start django

---
- name: Setup Database Server
  hosts: database
  become: yes
  vars:
    postgres_version: "13"
    db_name: "myproject"
    db_user: "django_user"
    db_password: "change_this_password"
    
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install PostgreSQL
      apt:
        name:
          - postgresql
          - postgresql-contrib
          - python3-psycopg2
          - ufw
          - htop
        state: present

    - name: Start and enable PostgreSQL
      systemd:
        name: postgresql
        enabled: yes
        state: started

    - name: Create database
      postgresql_db:
        name: "{{ db_name }}"
        state: present
      become_user: postgres

    - name: Create database user
      postgresql_user:
        name: "{{ db_user }}"
        password: "{{ db_password }}"
        priv: "{{ db_name }}:ALL"
        state: present
      become_user: postgres

    - name: Configure PostgreSQL to accept connections
      lineinfile:
        path: "/etc/postgresql/{{ postgres_version }}/main/postgresql.conf"
        regexp: "#listen_addresses = 'localhost'"
        line: "listen_addresses = 'localhost,{{ ansible_default_ipv4.address }}'"
      notify: restart postgresql

    - name: Configure PostgreSQL authentication for application server
      lineinfile:
        path: "/etc/postgresql/{{ postgres_version }}/main/pg_hba.conf"
        line: "host    {{ db_name }}    {{ db_user }}    {{ hostvars[groups['application'][0]]['ansible_default_ipv4']['address'] }}/32    md5"
      notify: restart postgresql

    - name: Configure UFW - Deny all incoming by default
      ufw:
        default: deny
        direction: incoming

    - name: Configure UFW - Allow SSH from gateway only
      ufw:
        rule: allow
        port: '22'
        proto: tcp
        src: "{{ hostvars[groups['gateway'][0]]['ansible_default_ipv4']['address'] }}"

    - name: Configure UFW - Allow PostgreSQL from application server
      ufw:
        rule: allow
        port: '5432'
        proto: tcp
        src: "{{ hostvars[groups['application'][0]]['ansible_default_ipv4']['address'] }}"

    - name: Enable UFW
      ufw:
        state: enabled

  handlers:
    - name: restart postgresql
      systemd:
        name: postgresql
        state: restarted