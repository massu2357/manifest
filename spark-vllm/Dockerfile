# NGC の vLLM イメージには Ray が含まれていない。
# 公式プレイブックは run_cluster.sh を sed でパッチして起動のたびに
# pip install ray していたが、それだと毎回 PyPI への通信が必要になる。
# ここで焼き込んでおくことで、起動が速くなり、オフラインでも動作する。
#
# ビルド:
#   docker build --build-arg HTTP_PROXY="$HTTP_PROXY" \
#                --build-arg HTTPS_PROXY="$HTTPS_PROXY" \
#                -t vllm-ray:26.05 .

FROM nvcr.io/nvidia/vllm:26.05-py3

ARG RAY_SPEC="ray[default]>=2.9"

# 社内CAがある場合は ./ca/ に .crt を置く（無ければ空でよい）
COPY ca/ /usr/local/share/ca-certificates/
RUN update-ca-certificates || true
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

RUN pip install --no-cache-dir --root-user-action=ignore "${RAY_SPEC}" \
 && ray --version
