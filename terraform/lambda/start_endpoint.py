import boto3
import os
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Starts (creates) the SageMaker endpoint using the existing endpoint configuration.
    Handles all endpoint states for idempotency.
    """
    endpoint_name = os.environ["ENDPOINT_NAME"]
    endpoint_config_name = os.environ["ENDPOINT_CONFIG_NAME"]
    region = os.environ.get("AWS_REGION", "eu-central-1")

    sagemaker = boto3.client("sagemaker", region_name=region)

    try:
        response = sagemaker.describe_endpoint(EndpointName=endpoint_name)
        status = response["EndpointStatus"]
        logger.info(f"Endpoint {endpoint_name} exists with status: {status}")

        if status == "InService":
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} is already InService",
            }

        if status in ["Creating", "Updating"]:
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} is already {status}",
            }

        if status == "Deleting":
            logger.warning(f"Endpoint {endpoint_name} is Deleting, cannot start now")
            raise RuntimeError(
                f"Endpoint {endpoint_name} is Deleting. Retry later."
            )

        if status == "Failed":
            logger.warning(f"Endpoint {endpoint_name} is Failed, deleting it")
            sagemaker.delete_endpoint(EndpointName=endpoint_name)
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} was Failed and is being deleted. Will recreate on next run.",
            }

        # Unknown status - log and raise
        logger.error(f"Endpoint {endpoint_name} has unknown status: {status}")
        raise RuntimeError(f"Unknown endpoint status: {status}")

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "ValidationException":
            logger.info(
                f"Endpoint {endpoint_name} does not exist, creating with config {endpoint_config_name}"
            )
            sagemaker.create_endpoint(
                EndpointName=endpoint_name, EndpointConfigName=endpoint_config_name
            )
            return {
                "statusCode": 200,
                "body": f"Endpoint {endpoint_name} creation initiated",
            }
        logger.error(f"ClientError: {error_code} - {str(e)}")
        raise

    except Exception as e:
        logger.error(f"Unexpected error starting endpoint: {str(e)}")
        raise
