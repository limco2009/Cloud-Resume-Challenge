import hmac
import json
import os
import boto3

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ.get("TABLE_NAME", "PageViews")
ORIGIN_SECRET = os.environ.get("ORIGIN_SECRET", "")
table = dynamodb.Table(TABLE_NAME)


def increment_view_count(page_id: str) -> int:
    response = table.update_item(
        Key={"page_id": page_id},
        UpdateExpression="SET #v = if_not_exists(#v, :start) + :inc",
        ExpressionAttributeNames={"#v": "views"},
        ExpressionAttributeValues={":start": 0, ":inc": 1},
        ReturnValues="UPDATED_NEW",
    )
    return int(response["Attributes"]["views"])


def lambda_handler(event, context):
    # 1. Verify that the request came through CloudFront using the secret header
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    incoming_secret = headers.get("x-origin-verify", "")

    if not ORIGIN_SECRET or not hmac.compare_digest(incoming_secret, ORIGIN_SECRET):
        return {
            "statusCode": 403,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Forbidden: Direct access not allowed"}),
        }

    # 2. Extract page_id and increment DynamoDB
    query_params = event.get("queryStringParameters") or {}
    page_id = query_params.get("page_id", "/")

    try:
        new_count = increment_view_count(page_id)
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"page_id": page_id, "views": new_count}),
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": str(e)}),
        }
