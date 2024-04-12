[root@ocpcluster7 iFixes]# cat IT45279-2.2.0-OPSMGR-README
Readme file for: IBM® Power Virtualization Center
Publication Date: Feb 09 2024


Note: Ensure that the name of the maintenance file is not changed when it is downloaded. This change might be intentional, or it might be an inadvertent change that is caused by certain web browsers or download utilities.

This iFix contains fix for the following issues:

 IT45279: OpsMgr iFix to enable support for RHEL 8.9 and RHEL 9.3

Part-A: Instructions for fresh installation of 2.2.0 on RHEL 8.9 and RHEL 9.3
--------------------------------------------------------------------------------------------

1) Install versionlock package :

   yum install python3-dnf-plugin-versionlock

2) Download the iFix bundle IT45279-2.2.0-OPSMGR.tgz and untar.

   tar -xvzf IT45279-2.2.0-OPSMGR.tgz


3) Download PowerVC 2.2.0 GA bundle(powervc-opsmgr-<OS-Architecture>-2.2.0.tgz) and untar.

   cd  <GA_bundle>

   To install OpsMgr, run

   sh setup_opsmgr.sh -s

4) Setup Inventory.

   powervc-opsmgr inventory -c cluster_Name

5) cd <ifix_tar_dir>

   sh patch_opsmgr.sh <cluster_name> <path_to_ifix_tar_bundle>

6) Proceed with the PowerVC install process on all nodes.

   nohup powervc-opsmgr install -c cluster_name -s


7) Run the following command from the primary node to apply iFix on non-primary PowerVC nodes.


   powervc-opsmgr apply-ifix --ifix <path_to_ifix_tar_bundle> -c <cluster_name> --host <hostname/hostip>

   Example : powervc-opsmgr apply-ifix --ifix /root/IT45279-2.2.0-OPSMGR.tgz -c rhel8ppcle --host <hostname/hostip>

   If the iFix installation fails for the host, rerun the command in step 7.




Part-B: Instructions to update the OS to RHEL 8.9 or RHEL 9.3 when PowerVC 2.2.0 is already installed.
--------------------------------------------------------------------------------------------------------------


1) Download the iFix bundle IT45279-2.2.0-OPSMGR.tgz to the PowerVC primary node and extract it by using the following command.

   tar -zxvf IT45279-2.2.0-OPSMGR.tgz


2) Install the OpsMgr iFix on the PowerVC primary node.

   cd IT45279-2.2.0-OPSMGR

   ./patch_opsmgr.sh <cluster_name> <path_to_ifix_tar_bundle>

3) Run the following command from the primary node to apply the iFix on non-primary PowerVC nodes.


   powervc-opsmgr apply-ifix --ifix <ifix-path> -c <cluster_name> --host <hostname/hostip>

   Example: powervc-opsmgr apply-ifix --ifix /root/IT45279-2.2.0-OPSMGR.tgz -c rhel8ppcle --host <hostname/hostip>

   If the iFix installation fails for the host, rerun the command in Step 3.

4) Perform yum update to 8.9 if you are on a previous supported 8.x version of PowerVC 2.2.0.

   or

5) Perform yum update to 9.3 if you are on a previous supported 9.x version of PowerVC 2.2.0.


  Note: The <cluster_name> can be obtained by running "powervc-opsmgr inventory -l" command.
  If the inventory is created with hostname, then use hostname in the apply-ifix command. If hostip is used when the inventory is created, then use the hostip in the apply-ifix command.


Part-C: Instructions for upgrade to 2.2.0 
--------------------------------------------------------------------------------------------

1) Download PowerVC 2.2.0 GA bundle (powervc-opsmgr-<OS-Architecture>-2.2.0.tgz) and untar.
   cd  <GA_bundle>
   To update the OpsMgr, run
   sh update_opsmgr.sh -s

2) Proceed with the PowerVC upgrade process on all nodes.

3) Download the iFix bundle IT45279-2.2.0-OPSMGR.tgz and untar.

   tar -xvzf IT45279-2.2.0-OPSMGR.tgz

4) Install the OpsMgr iFix on the PowerVC primary node.

   cd IT45279-2.2.0-OPSMGR

   ./patch_opsmgr.sh <cluster_name> <path_to_ifix_tar_bundle>


5) Run the following command from the primary node to apply iFix on non-primary PowerVC nodes.


   powervc-opsmgr apply-ifix --ifix <path_to_ifix_tar_bundle> -c <cluster_name> --host <hostname/hostip>

   Example: powervc-opsmgr apply-ifix --ifix /root/IT45279-2.2.0-OPSMGR.tgz -c rhel8ppcle --host <hostname/hostip>

   If the iFix installation fails for the host, rerun the command in step 5.

6) Perform yum update to 8.9 if you are on a previous supported 8.x version of PowerVC 2.2.0.

   or

7) Perform yum update to 9.3 if you are on a previous supported 9.x version of PowerVC 2.2.0.



  Note: The <cluster_name> can be obtained by running "powervc-opsmgr inventory -l" command.
  If the inventory is created with hostname, then use hostname in the apply-ifix command. If hostip is used when the inventory is created, then use the hostip in the apply-ifix command.

# Below rpms are installed after the iFix is successfully applied:

RHEL 8.9:

# yum repo-pkgs ifix-IT45279-2.2.0-OPSMGR list
Updating Subscription Management repositories.
Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)                                                                                                                               23 kB/s | 4.5 kB     00:00
Red Hat Enterprise Linux 8 for x86_64 - High Availability (RPMs)                                                                                                                       22 kB/s | 4.0 kB     00:00
Red Hat Enterprise Linux 8 for x86_64 - Supplementary (RPMs)                                                                                                                           23 kB/s | 3.8 kB     00:00
Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)                                                                                                                                  23 kB/s | 4.1 kB     00:00
Installed Packages
powervc-opsmgr.noarch                                                                         2.2.0-202401301145.2.ibm.el8                                                                  @ifix-IT45279-2.2.0-OPSMGR
python3-powervc-opsmgr.noarch                                                                 2.2.0-202401301145.2.ibm.el8                                                                  @ifix-IT45279-2.2.0-OPSMGR



RHEL 9.3:

# yum repo-pkgs ifix-IT45279-2.2.0-OPSMGR list
Updating Subscription Management repositories.
Red Hat Enterprise Linux 9 for x86_64 - Supplementary (RPMs)                                                                                                                           23 kB/s | 3.7 kB     00:00
Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)                                                                                                                               26 kB/s | 4.5 kB     00:00
Red Hat Enterprise Linux 9 for x86_64 - High Availability (RPMs)                                                                                                                       24 kB/s | 4.0 kB     00:00
Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)                                                                                                                                  25 kB/s | 4.1 kB     00:00
Red Hat CodeReady Linux Builder for RHEL 9 x86_64 (RPMs)                                                                                                                               28 kB/s | 4.5 kB     00:00
Installed Packages
powervc-opsmgr.noarch                                                                         2.2.0-202401301145.2.ibm.el8                                                                  @ifix-IT45279-2.2.0-OPSMGR
python3-ply.noarch                                                                            3.11-21.ibm.el9                                                                               @ifix-IT45279-2.2.0-OPSMGR
python3-powervc-opsmgr.noarch                                                                 2.2.0-202401301145.2.ibm.el8                                                                  @ifix-IT45279-2.2.0-OPSMGR

python3-rtslib-fb.noarch       @ifix-IT45279-2.2.0-OPSMGR				      2.1.75-3.ibm.el8


Copyright and trademark information  http://www.ibm.com/legal/copytrade.shtml

Notices

INTERNATIONAL BUSINESS MACHINES CORPORATION PROVIDES THIS PUBLICATION "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Some jurisdictions do not allow disclaimer of express or implied warranties in certain transactions, therefore, this statement may not apply to you.

This information could include technical inaccuracies or typographical errors. Changes are periodically made to the information herein; these changes will be incorporated in new editions of the publication. IBM may make improvements and/or changes in the product(s) and/or the program(s) described in this publication at any time without notice.

Microsoft, Windows, and Windows Server are trademarks of Microsoft Corporation in the United States, other countries, or both.

Intel, Intel logo, Intel Inside, Intel Inside logo, Intel Centrino, Intel Centrino logo, Celeron, Intel Xeon, Intel SpeedStep, Itanium, and Pentium are trademarks or registered trademarks of Intel Corporation or its subsidiaries in the United States and other countries.

Other company, product, or service names may be trademarks or service marks of others.

Third-Party License Terms and Conditions, Notices and Information

The license agreement for this product refers you to this file for details concerning terms and conditions applicable to third party software code included in this product, and for certain notices and other information IBM must provide to you under its license to certain software code. The relevant terms and conditions, notices and other information are provided or referenced below. Please note that any non-English version of the licenses below is unofficial and is provided to you for your convenience only. The English version of the licenses below, provided as part of the English version of this file, is the official version.

Notwithstanding the terms and conditions of any other agreement you may have with IBM or any of its related or affiliated entities (collectively "IBM"), the third party software code identified below are "Excluded Components" and are subject to the following terms and conditions:
* the Excluded Components are provided on an "AS IS" basis.
* IBM DISCLAIMS ANY AND ALL EXPRESS AND IMPLIED WARRANTIES AND CONDITIONS WITH RESPECT TO THE EXCLUDED COMPONENTS, INCLUDING, BUT NOT LIMITED TO, THE WARRANTY OF NON-INFRINGEMENT OR INTERFERENCE AND THE IMPLIED WARRANTIES AND CONDITIONS OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
* IBM will not be liable to you or indemnify you for any claims related to the Excluded Components.
* IBM will not be liable for any direct, indirect, incidental, special, exemplary, punitive or consequential damages with respect to the Excluded Components.


Document change history