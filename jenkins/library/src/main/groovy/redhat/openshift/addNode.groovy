import hudson.model.AbstractBuild
import hudson.model.Node
import hudson.plugins.sshslaves.SSHLauncher
import hudson.plugins.sshslaves.verifiers.NonVerifyingKeyVerificationStrategy
import hudson.plugins.sshslaves.verifiers.SshHostKeyVerificationStrategy
import hudson.slaves.ComputerLauncher
import hudson.slaves.DumbSlave
import hudson.util.VariableResolver
import jenkins.model.Jenkins

Jenkins jenkins = Jenkins.getInstance()

Thread thread = Thread.currentThread()
AbstractBuild build = thread.executable
VariableResolver<String> resolver = build.getBuildVariableResolver()

String nodeHostname = resolver.resolve("NODE_HOSTNAME")
String nodeCredentialID = resolver.resolve("NODE_CREDENTIAL_ID")
SshHostKeyVerificationStrategy strategy = new NonVerifyingKeyVerificationStrategy()
ComputerLauncher nodeLauncher = new SSHLauncher(
        nodeHostname, 22, nodeCredentialID,
        null, null,
        null, null,
        30, 20, 10,
        strategy,
)

String nodeName = resolver.resolve("NODE_NAME")
String nodeRemoteFS = "/var/lib/jenkins"
Node node = new DumbSlave(
        nodeName,
        nodeRemoteFS,
        nodeLauncher
)
node.setNumExecutors(1)

jenkins.addNode(node)