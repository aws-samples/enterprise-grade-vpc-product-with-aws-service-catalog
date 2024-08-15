#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Script to install the CloudFormation templates relating to the Service Catalog product
# for sharing an advanced customisable VPC product to requesting accounts.

set -eu

function get_stack_output() {
  local stack="$1"
  local output="$2"

  value=$(aws --output text cloudformation describe-stacks --stack-name $stack --query "Stacks[].Outputs[?OutputKey=='"$output"'].OutputValue[]")

  if [ -z "$value" ]; then
    >&2 echo "Could not get the Output $output from stack $stack"
    return 1
  fi
  echo $value
}

function get_existing_stack_value_or_default(){
  local stack="$1"
  local parameter="$2"
  local default="$3"
  value=$( aws --output text cloudformation describe-stacks --stack-name $stack --query "Stacks[].Parameters[?ParameterKey==\`$parameter\`]".ParameterValue 2>/dev/null )
  if [ -z "$value" ]; then
    echo $default
  else
    echo $value
  fi
}

sc_stack_name="VPC-Service-Catalog"
ipam_stack_name="IPAM"
bucket_stack_name="VPC-SC-Bucket"
vpc_flow_log_bucket_stack_name="VPC-Flow-Log-Bucket"
sc_product_template_filename="VPC-Product.yaml"

# VPC Flow Log bucket name (blank means it'd create an VPC flow log the sample template in this repo)
read -p "If you used the provided VPC Flow Log template, press enter here to keep this blank. Otherwise, enter the logging bucket name ID: " vpc_flow_log_bucket_name

# OU ids to share IPAM pools with 
prod_ou_arns=$(get_existing_stack_value_or_default $ipam_stack_name "ProdOuArns" "")
read -p "AWS IP Address Manager (IPAM) pools will be created by defalt, please enter the ARNs for prod OU to be assigned with prod IPAM pool, separated by comma [$prod_ou_arns]: " user_input
test ! -z "$user_input" && prod_ou_arns="$user_input"

nonprod_ou_arns=$(get_existing_stack_value_or_default $ipam_stack_name "NonProdOuArns" "")
read -p "Enter the ARNs for nonprod OU, separated by comma: [$nonprod_ou_arns]" user_input
test ! -z "$user_input" && nonprod_ou_arns="$user_input"

# Get company/org name
provider_name=$(get_existing_stack_value_or_default $sc_stack_name "ProviderName" "TestOrg")
read -p "Enter a short organization/company name to use as the Service Catalog provider name, no spaces [$provider_name]: " user_input
test ! -z "$user_input" && provider_name="$user_input"

# Get service catalog product version
sc_product_version=$(get_existing_stack_value_or_default $sc_stack_name "ProductVersion" "v1")
read -p "Enter the product version with no spaces (increment this if you updated the VPC-Product.yaml file) [$sc_product_version]: " user_input
test ! -z "$user_input" && sc_product_version="$user_input"

# Principal type
sc_principal_type=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalType" "IAM_Identity_Center_Permission_Set")
read -p "Type of principal that will use the product, IAM_Identity_Center_Permission_Set or IAM_role_name [$sc_principal_type]: " user_input
test ! -z "$user_input" && sc_principal_type="$user_input"

# If the principal type is IAM Identity Center, we need the IAM Identity Center home region:
if [[ "$sc_principal_type" == "IAM_Identity_Center_Permission_Set" ]]; then
#   sc_iam_identity_center_region=$(get_existing_stack_value_or_default $sc_stack_name "IAMIdentityCenterRegion" "$AWS_DEFAULT_REGION")
  sc_iam_identity_center_region=$(get_existing_stack_value_or_default $sc_stack_name "IAMIdentityCenterRegion" "ap-southeast-2")
  read -p "IAM Identity Center home region [$sc_iam_identity_center_region]: " user_input
  test ! -z "$user_input" && sc_iam_identity_center_region="$user_input"
fi

# Principal name 01
sc_principal_name_01=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalName01" "AWSAdministratorAccess")
read -p "IAM role name or permission set that can access the Service Catalog product [$sc_principal_name_01]: " user_input
test ! -z "$user_input" && sc_principal_name_01="$user_input"

# Principal name 02
sc_principal_name_02=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalName02" "")
read -p "(Optional, leave blank to skip) Additional IAM role name or permission set that can access the Service Catalog product [$sc_principal_name_02]: " user_input
test ! -z "$user_input" && sc_principal_name_02="$user_input"

echo "Make sure you are logged into the AWS account and region where you want to host your VPC service catalog product, and press enter to start the installation..."
read x

# Create IPAM pools

sam deploy \
  --template-file ../ipam/IPAM.yaml \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ParameterKey=ProdOuArns,ParameterValue=$prod_ou_arns \
    ParameterKey=NonProdOuArns,ParameterValue=$nonprod_ou_arns \
  --capabilities CAPABILITY_NAMED_IAM \
  --stack-name $ipam_stack_name

prod_pool_id=$(get_stack_output $ipam_stack_name MainRegionProdPoolID)
nonprod_pool_id=$(get_stack_output $ipam_stack_name MainRegionNonProdPoolID)

# Create bucket that will contain the product template:

sam deploy \
  --template-file service-catalog-product-template-bucket/VPC-SC-Bucket.yaml \
  --no-fail-on-empty-changeset \
  --stack-name $bucket_stack_name
bucket=$(get_stack_output $bucket_stack_name BucketName)
s3_url=$(get_stack_output $bucket_stack_name BucketURL)

echo "Bucket stack creation finished successfully."


# Create VPC Flow Log bucket if not using existing 

if [[ ! $vpc_flow_log_bucket_name ]]; then

sam deploy \
  --template-file ../vpc-flow-log-bucket/VPC-Flow-Log-Bucket.yaml \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ParameterKey=LogRetentionDays,ParameterValue=180 \
    ParameterKey=BucketPrefix,ParameterValue="vpc-flow-logs" \
    ParameterKey=LogInfrequentAccessDays,ParameterValue=90\
  --capabilities CAPABILITY_NAMED_IAM \
  --stack-name $vpc_flow_log_bucket_stack_name

vpc_flow_log_bucket_name=$(get_stack_output $vpc_flow_log_bucket_stack_name Bucket)
fi

# Replace placeholders in the template, and upload to bucket:
tgw_id=$(aws --output text ec2 describe-transit-gateways --query "TransitGateways[0].TransitGatewayId")

# Network Account ID
network_account_id=$(aws --output text sts get-caller-identity --query "Account")

sed \
  -e "s/ipam-pool-abc/$prod_pool_id/g" \
  -e "s/ipam-pool-xyz/$nonprod_pool_id/g" \
  -e "s/01234/$network_account_id/g" \
  -e "s/tgw-xyz/$tgw_id/g" \
  -e "s/xyz/$vpc_flow_log_bucket_name/g" \
  ../vpc/${sc_product_template_filename} \
  | aws s3 cp - s3://${bucket}/${sc_product_template_filename}

# Create the Service Catalog product:
sam deploy \
  --template-file service-catalog-portfolio/VPC-ServiceCatalog.yaml \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ParameterKey=ProviderName,ParameterValue="$provider_name" \
    ParameterKey=ProductVersion,ParameterValue=$sc_product_version \
    ParameterKey=VPCTemplateURL,ParameterValue=${s3_url}/${sc_product_template_filename} \
    ParameterKey=PrincipalType,ParameterValue=$sc_principal_type \
    ParameterKey=PrincipalName01,ParameterValue=$sc_principal_name_01 \
    ParameterKey=PrincipalName02,ParameterValue=$sc_principal_name_02 \
    ParameterKey=IAMIdentityCenterRegion,ParameterValue=$sc_iam_identity_center_region \
  --capabilities CAPABILITY_NAMED_IAM \
  --stack-name $sc_stack_name

echo "Product stack creation finished successfully."

# Sharing options, via the CLI until this is closed: https://github.com/aws-cloudformation/cloudformation-coverage-roadmap/issues/594
read -p "Enter 'org' if you want to share the portfolio to the entire Organization. Enter 'account' if you want to share with a specific account. Otherwise, enter 'n' and use the AWS Management Console to share to a specific OU. [org/account/n]: " sharing_method
portfolio_id=$(get_stack_output $sc_stack_name PortfolioID)
organization_id=$(aws --output text organizations describe-organization --query Organization.Id)

if [[ "$sharing_method" == "org" ]]; then
  # Share the portfolio with the org:
  aws servicecatalog create-portfolio-share \
    --portfolio-id $portfolio_id \
    --share-principals \
    --organization-node Type=ORGANIZATION,Value=$organization_id
elif [[ "$sharing_method" == "account" ]]; then
  # Share the portfolio with given account:
  read -p "Enter the account ID to share with: " account_id
  aws servicecatalog create-portfolio-share \
    --portfolio-id $portfolio_id \
    --share-principals \
    --organization-node Type=ACCOUNT,Value=$account_id
fi

echo "Done!"

