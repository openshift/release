BRANCH = master

.PHONY: status
status:
	@git submodule

# Creates a new release branch for FROM, then creates a new commit into master and
# tags it as TO, then pushes both to upstream.
.PHONY: branch
branch:
ifndef FROM
	$(error Must set FROM= to the major/minor version of the current release, e.g. 3.9)
endif
ifndef TO
	$(error Must set TO= to the major/minor version of the next release, e.g. 3.10)
endif
	git submodule foreach '! git rev-parse release-$(FROM) &>/dev/null'
	git submodule foreach '! git rev-parse v$(TO).0-alpha.0 &>/dev/null'
	git submodule foreach git checkout -b release-$(FROM) $(BRANCH)
	git submodule foreach git checkout $(BRANCH)
	git submodule foreach 'echo $(TO) > .release; git add .release; git commit -S -m "Branch for v$(TO)"'
	git submodule foreach git tag -f -s -a -m "v$(TO).0-alpha.0" v$(TO).0-alpha.0
	git submodule foreach git push origin "release-$(FROM)" "v$(TO).0-alpha.0"

# Ensures the latest BRANCH commit is reflected in this repository.
.PHONY: sync
sync:
	git submodule foreach git fetch origin
	git submodule foreach git checkout $(BRANCH)
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
