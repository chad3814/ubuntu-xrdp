# syntax=docker/dockerfile:1.7
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

CMD ["/bin/bash"]
