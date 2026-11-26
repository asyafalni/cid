# A network share for tests/nas.sh: a user-space NFSv3 server (unfs3), so
# the test needs no kernel NFS server and no privileges. It exports
# /export; mount and NFS both answer on 2049.
FROM alpine:3.22
RUN apk add --no-cache unfs3 && mkdir /export && echo '/export (rw,no_root_squash,insecure)' > /etc/exports
EXPOSE 2049
CMD ["unfsd", "-d", "-p", "-t", "-n", "2049", "-m", "2049", "-e", "/etc/exports"]
