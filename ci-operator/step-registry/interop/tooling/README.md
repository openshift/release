# interop-tooling<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Procedures](#procedures)
  - [Contribution](#contribution)
    - [Modifying a Tool](#modifying-a-tool)
    - [Creating a New Tool](#creating-a-new-tool)
  - [Documentation](#documentation)
- [Tools](#tools)
  - [Operator Management](#operator-management)
  - [Miscellaneous](#miscellaneous)

## Purpose

The tools in this folder are created and maintained by the Interop QE team. These tools have been created with the original purpose to be used within Interop testing scenarios, however, these tools may be used elsewhere and by other teams. If your team is planning on modifying any of the tools in this folder, please follow the guidelines we have put together in the [procedures](#procedures) section of this document.

## Procedures

### Contribution

Please follow these guidelines when contributing to interop-tooling.

#### Modifying a Tool

1. **If you are not a member of the Interop QE team** - Before merging any changes to these tools, please request Interop QE to verify the changes made will not interfere with current Interop testing.
2. Maintain the current standard of keeping the tools modular and reusable. These tools should be re-usable in any scenario.
3. Keep code idempotent (where possible), clean, and easy to read.
4. Keep the README document for any modified tool up to date and accurate.

#### Creating a New Tool

A new tool should be created if the proposed tool could be useful in more than one scenario. None of the tools in this folder should be specific to one scenario or test. If you decide to create a new tool in this folder, please follow these guidelines:
1. The tool should be...
   1. Idempotent, where possible
   2. Useful
   3. Modular
   4. Reusable
2. Keep any code readable and clean
   1. Use descriptive variables (not `x`)
   2. Leave comments explaining what the code does
   3. Add messages for logging and debugging
3. [Create a README file](#documentation) to document the tool
   1. Also, please add it to the [tools](#tools) section below
4. **Don't duplicate work**

### Documentation

All tools in interop-tooling should have a README file associated with them. If there is not a README in the tool's folder, please add one and add documentation to it. The documentation should adhere to the following structure:

1. Title
   1. Table of Contents
   2. Purpose (Why is this being created? What does it do?)
   3. Process (How does this tool work?)
   4. Container Used (Which container is used. i.e. built-in `cli` or a custom image)
   5. Requirements
      1. Variables (Any environment variables used, their definition and default values)
      2. Infrastructure (Any infrastructure needed to execute. Cluster, networking, etc.)
      3. Credentials (Any credentials stored in Vault to be used during the tools execution)

Feel free to add additional subsections, but please at least include the information above. If you need an example, read another tool's README file.

## Tools

### Operator Management

- [interop-tooling-operator-install](operator-install/README.md)
  - Install an optional operator to a target test cluster

### Miscellaneous

- [interop-tooling-deploy-selenium-ref](deploy-selenium/README.md)
  - Deploy a Selenium pod to a target test cluster for remote Selenium execution