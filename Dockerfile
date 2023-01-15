FROM nginx
EXPOSE 80
COPY hugo/public/ /usr/share/nginx/html
