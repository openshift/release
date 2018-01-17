BRANCH = master

.PHONY: status
status:
	@git submodule

.PHONY: branch
branch:
ifndef WHAT
	$(error Must set WHAT= to the name of the branch to create)
endif
	git submodule foreach git checkout -b $(WHAT) $(BRANCH)
	git submodule foreach echo git push origin $(WHAT)

# Ensures the latest BRANCH commit is reflected in this repository.
.PHONY: sync
sync:
	git submodule foreach git fetch origin
	git submodule foreach git reset origin/$(BRANCH) --hard

# Tag the current status of the repository as WHAT, and push those tags.
.PHONY: tag
tag:
ifndef WHAT
	$(error Must set WHAT= to the name of the tag to create)
endif
	git submodule foreach git tag -f -s -a -m "$(WHAT)" $(WHAT)
	git submodule foreach git push origin --tags "$(WHAT)"

# Replace the 'origin' remote in each submodule with a Git private remote to allow push operations.
.PHONY: fetch-private
fetch-private:
	git submodule foreach 'a=`echo $$path | cut -c 16-`; git remote rm origin; git remote add origin git@github.com:$$a.git; git fetch origin'
