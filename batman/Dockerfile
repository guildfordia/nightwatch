FROM debian:bullseye

RUN apt-get update && apt-get install -y \
    iproute2 iw batctl iputils-ping python3 python3-pip \
 && apt-get clean

# (optional) if you want your Python monitor:
# COPY ./batman/requirements.txt /tmp/requirements.txt
# RUN pip3 install --no-cache-dir -r /tmp/requirements.txt

# Copy a status script that only reads, never configures
COPY ./batman/scripts/mesh-status.sh /usr/local/bin/mesh-status.sh
RUN chmod +x /usr/local/bin/mesh-status.sh

# If you have the Python monitor instead:
# COPY ./batman /opt/batman
# WORKDIR /opt/batman
# CMD ["python3", "main.py"]

CMD ["/usr/local/bin/mesh-status.sh"]
