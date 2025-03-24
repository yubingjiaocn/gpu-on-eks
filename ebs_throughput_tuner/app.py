import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Lambda function to modify EBS volume throughput and IOPS for EC2 instances
    with specific tags. Handles both EC2 state change events and EC2 Fleet/Spot Fleet events.
    """
    logger.info(f"Event received: {event}")

    # Get environment variables
    tag_key = os.environ.get('TARGET_EC2_TAG_KEY', 'stack')
    tag_value = os.environ.get('TARGET_EC2_TAG_VALUE')
    throughput = int(os.environ.get('THROUGHPUT_VALUE', '125'))
    iops = int(os.environ.get('IOPS_VALUE', '3000'))

    if not tag_value:
        logger.error("TARGET_EC2_TAG_VALUE environment variable is not set")
        return {
            'statusCode': 400,
            'body': 'TARGET_EC2_TAG_VALUE environment variable is not set'
        }

    # Extract instance ID from the event
    instance_id = None

    # Check event source and extract instance ID accordingly
    detail_type = event.get('detail-type', '')

    if detail_type == 'EC2 Instance State-change Notification':
        instance_id = event.get('detail', {}).get('instance-id')
        logger.info(f"Extracted instance ID from EC2 state change event: {instance_id}")

    ec2_client = boto3.client('ec2')
    modified_volumes = []

    # If we have a specific instance ID from the event, process just that instance
    if instance_id:
        process_instance(ec2_client, instance_id, tag_key, tag_value, throughput, iops, modified_volumes)
    else:
        # Otherwise, find all instances with the specified tag (fallback behavior)
        logger.info(f"No instance ID found in event, searching for instances with tag {tag_key}={tag_value}")
        find_and_process_instances(ec2_client, tag_key, tag_value, throughput, iops, modified_volumes)

    return {
        'statusCode': 200,
        'body': f'Modified {len(modified_volumes)} volumes: {modified_volumes}'
    }

def process_instance(ec2_client, instance_id, tag_key, tag_value, throughput, iops, modified_volumes):
    """Process a single instance to modify its EBS volumes."""
    try:
        # First check if the instance exists and get its state
        instance_response = ec2_client.describe_instances(InstanceIds=[instance_id])

        # Check if instance exists
        if not instance_response['Reservations'] or not instance_response['Reservations'][0]['Instances']:
            logger.info(f"Instance {instance_id} not found")
            return

        # Check if instance is terminated
        instance_state = instance_response['Reservations'][0]['Instances'][0]['State']['Name']
        if instance_state == 'terminated':
            logger.info(f"Instance {instance_id} is terminated. Skipping processing.")
            return

        # Now check if the instance has the required tag
        response = ec2_client.describe_instances(
            InstanceIds=[instance_id],
            Filters=[
                {
                    'Name': f'tag:{tag_key}',
                    'Values': [tag_value]
                }
            ]
        )

        # If no matching instances found, log and return
        if not response['Reservations'] or not response['Reservations'][0]['Instances']:
            logger.info(f"Instance {instance_id} does not have the required tag {tag_key}={tag_value}")
            return

        # Process the instance
        instance = response['Reservations'][0]['Instances'][0]
        logger.info(f"Processing instance: {instance_id}")

        # Get volumes attached to the instance
        for block_device in instance.get('BlockDeviceMappings', []):
            if 'Ebs' in block_device:
                volume_id = block_device['Ebs']['VolumeId']
                modify_volume(ec2_client, volume_id, throughput, iops, modified_volumes)

    except Exception as e:
        logger.error(f"Error processing instance {instance_id}: {str(e)}")

def find_and_process_instances(ec2_client, tag_key, tag_value, throughput, iops, modified_volumes):
    """Find all instances with the specified tag and process them."""
    try:
        response = ec2_client.describe_instances(
            Filters=[
                {
                    'Name': f'tag:{tag_key}',
                    'Values': [tag_value]
                }
            ]
        )

        # Process each instance
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                instance_id = instance['InstanceId']
                logger.info(f"Processing instance: {instance_id}")

                # Get volumes attached to the instance
                for block_device in instance.get('BlockDeviceMappings', []):
                    if 'Ebs' in block_device:
                        volume_id = block_device['Ebs']['VolumeId']
                        modify_volume(ec2_client, volume_id, throughput, iops, modified_volumes)

    except Exception as e:
        logger.error(f"Error finding and processing instances: {str(e)}")

def modify_volume(ec2_client, volume_id, throughput, iops, modified_volumes):
    """Modify a single EBS volume if it's gp3 type."""
    try:
        # Get current volume attributes
        volume_info = ec2_client.describe_volumes(VolumeIds=[volume_id])
        volume = volume_info['Volumes'][0]
        volume_type = volume['VolumeType']

        # Only modify gp3 volumes
        if volume_type == 'gp3':
            logger.info(f"Modifying volume: {volume_id}")
            try:
                ec2_client.modify_volume(
                    VolumeId=volume_id,
                    Throughput=throughput,
                    Iops=iops
                )
                modified_volumes.append(volume_id)
                logger.info(f"Successfully modified volume {volume_id} with throughput={throughput}, iops={iops}")
            except Exception as e:
                logger.error(f"Error modifying volume {volume_id}: {str(e)}")
        else:
            logger.info(f"Skipping volume {volume_id} of type {volume_type} (not gp3)")
    except Exception as e:
        logger.error(f"Error getting volume info for {volume_id}: {str(e)}")