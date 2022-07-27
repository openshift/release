SRC=openshift
TGT=theokdexperience

for dir in `ls -d *`
do	
        pushd `pwd` >/dev/null	
	cd ${dir}
	echo ${dir}

	for file in `ls ${SRC}*.yaml 2>/dev/null`
	do	
		target=$(echo ${file}| sed -e s!${SRC}!${TGT}!)
		mv -f $file $target 2>/dev/null
	done
	popd >/dev/null
done

for dir in `ls -d *`
#for dir in `ls -d machine-config-operator`
do
        pushd `pwd` >/dev/null	
	cd ${dir}
	echo ${dir}
	for file in `ls ${TGT}*.yaml 2>/dev/null`
	do
		OKD_FILE=$(echo ${file} | sed -e "s/.yaml/__okd.yaml/")
                echo "  ${file}"

                if [[ $(yq '.promotion.namespace' ${file}) != 'null' ]]
		then
			if [[ -f ${OKD_FILE} || $(echo ${file} | grep fcos) ]]
			then	
		    		echo "    OKD Version exists so promote original to 'origin-ocp'"	  
		    		yq -i '.promotion.namespace = "origin-ocp"' ${file}
                	else
		    		yq -i '.promotion.namespace = "okd"' ${file}
		  	fi  
                fi 

                if [[ $(yq '.zz_generated_metadata.org' ${file}) != 'null' ]]
		then	
		  yq -i '.zz_generated_metadata.org = "theokdexperience"' ${file}
		fi  

                if [[ $(yq '.releases.initial.integration.namespace' ${file}) != 'null' ]]
		then	
		  yq -i '.releases.initial.integration.namespace = "okd"' ${file}
		fi  

                if [[ $(yq '.releases.latest.integration.namespace' ${file}) != 'null' ]]
		then	
		  yq -i '.releases.latest.integration.namespace = "okd"' ${file}
		fi  
	done

	popd >/dev/null
done
