for file in `find . -name *.yaml`
do
	echo ${file}
	echo >> ${file}
done
