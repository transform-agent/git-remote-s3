ExUnit.start()

# Declare all Mox mocks used by the test suite.
Mox.defmock(GitRemoteS3.MockS3Client, for: GitRemoteS3.S3ClientBehaviour)
