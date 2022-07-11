from base64 import b64encode
from configparser import ConfigParser
from hashlib import sha256
from http.cookies import SimpleCookie
from os import environ
from os import urandom
from textwrap import dedent
from urllib.parse import urlsplit
from urllib.parse import urlunsplit
import hmac
import json

from botocore.session import Session
from botocore.auth import S3SigV4QueryAuth
from botocore.awsrequest import AWSRequest

COOKIE_NAME = "secret"
HEADER_NAME = "cf-auth"

parser = ConfigParser()
parser.read(environ["LAMBDA_TASK_ROOT"] + "/config.ini")
config = parser["default"]

load_credentials = Session().get_component("credential_provider").load_credentials


def _replace_domain(url, domain):
    split = urlsplit(url)
    return urlunsplit(split._replace(netloc=domain))


def _authed_request(*, pepper, secret, region, bucket, path, domain):
    credentials = load_credentials()
    auth = S3SigV4QueryAuth(credentials, "s3", region)

    mac = hmac.new(pepper.encode(), f"{secret}/{path}".encode(), sha256).digest()
    headers = {HEADER_NAME: b64encode(mac).decode()}
    url = f"https://{bucket}.s3.{region}.amazonaws.com/{path}"

    # Synthesize a request and sign it.
    synthetic_request = AWSRequest(method="GET", url=url, headers=headers)
    auth.add_auth(synthetic_request)
    return _replace_domain(synthetic_request.url, domain)


def _get_cookies(headers):
    ret = dict()
    try:
        cookies = headers["cookie"][0]["value"]
    except KeyError:
        return ret

    return dict((k, v.value) for k, v in SimpleCookie(cookies).items())


def _to_headers(d):
    return {key: [dict(key=key, value=value)] for key, value in d.items()}


def _generate_token():
    return b64encode(urandom(16)).decode().replace("=", "")


def lambda_handler(event, context):
    request = event["Records"][0]["cf"]["request"]
    cookies = _get_cookies(request["headers"])

    headers = {"content-type": "text/html"}

    token = cookies.get(COOKIE_NAME, None)
    if token is None:
        token = _generate_token()
        headers["set-cookie"] = f"{COOKIE_NAME}={token}; Secure; HttpOnly; SameSite=Lax"

    url = _authed_request(
        pepper=config["pepper"],
        secret=token,
        region=config["s3_bucket_region"],
        bucket=config["s3_bucket"],
        path=config["s3_object"],
        domain=config["cf_domain"],
    )

    headers["location"] = url

    body = dedent(
        f"""\
        <!DOCTYPE html>
        <html>
        <body>
            <a href="{url}">Click me!</a>
        </body>
        </html>
        """
    )

    return dict(
        status=302,
        statusDescription="Found",
        headers=_to_headers(headers),
        body=body,
    )
