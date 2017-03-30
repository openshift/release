import hudson.model.AbstractBuild
import hudson.model.Node
import hudson.util.VariableResolver
import jenkins.model.Jenkins

Thread thread = Thread.currentThread()
AbstractBuild build = thread.executable
VariableResolver<String> resolver = build.getBuildVariableResolver()
String nodeName = resolver.resolve("NODE_NAME")

Jenkins jenkins = Jenkins.getInstance()
Node node = jenkins.getNode(nodeName)
jenkins.removeNode(node)