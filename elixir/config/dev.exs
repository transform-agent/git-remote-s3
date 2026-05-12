import Config

# In dev/prod use the real ExAws S3 client.
config :git_remote_s3, :s3_client, GitRemoteS3.ExAwsS3Client
