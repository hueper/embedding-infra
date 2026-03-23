import boto3
import os
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Stops (deletes) the SageMaker endpoint to save costs.
    The endpoint configuration is preserved for recreation.
    Handles all endpoint states for idempotency.
    """
    endpoint_name = os.environ["ENDPOINT_NAME"]
    region = os.environ.get("AWS_REGION", "eu-central-1")

    sagemaker = boto3.client("sagemaker", region_name=region)

    try:
        response = sagemaker.describe_endpoint(EndpointName=endpoint_name)
        status = response["EndpointStatus"]
        logger.info(f"Endpoint {endpoint_name} exists with status: {status}")

        if status == "Deleting":
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} is already Deleting",
            }

        if status in ["InService", "Creating", "Updating", "Failed"]:
            logger.info(f"Deleting endpoint {endpoint_name} (current status: {status})")
            sagemaker.delete_endpoint(EndpointName=endpoint_name)
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} deletion initiated",
            }

        # Unknown status - log and attempt deletion anyway
        logger.warning(f"Endpoint {endpoint_name} has unknown status: {status}, attempting deletion")
        sagemaker.delete_endpoint(EndpointName=endpoint_name)
        return {
            "statusCode": 200,
            "body": f"Endpoint {endpoint_name} deletion initiated (was in unknown status: {status})",
        }

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "ValidationException":
            logger.info(f"Endpoint {endpoint_name} does not exist, nothing to delete")
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} does not exist",
            }
        logger.error(f"ClientError: {error_code} - {str(e)}")
        raise

    except Exception as e:
        logger.error(f"Unexpected error stopping endpoint: {str(e)}")
        raise
