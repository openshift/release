#!/usr/bin/env python3

import yaml
import sys
import os
from inspect import getframeinfo, stack
import pathlib

# If set to True, a call to gendoc will simply read & rewrite a filename in lexical order.
# This may be used as a first pass to help reduce git diffs between hand crafted and generated
# files when first making the transition.
SORT_ONLY = False


class GenDoc():

    def __init__(self, filename_or_stream, context=None):
        """
        :param filename_or_stream: The filename or stream to which yaml resources should be serialized.
        :param context: The context object to store and make available to rendering functions
        """
        if isinstance(filename_or_stream, pathlib.Path):
            filename_or_stream = str(filename_or_stream)
        self.filename_or_stream = filename_or_stream
        self.stream = None
        self.owns_file = False
        self.resources = []
        self.comments = {}  # Maps resource index to a list of comments
        self.context = context
        self.who = {}  # Maps resource index to the caller who added the resource

        # This flag should only be set to True when a user is attempting to reformat a file
        # prior to generating its content. This step allows git diffs to be far more
        # comparable when migrating from hand-crafted to migrated resources.
        self.sort_only = SORT_ONLY
        if self.sort_only:
            self.sort_file()

    def sort_file(self):
        if not isinstance(self.filename_or_stream, str):
            # This is a stream and can't be sorted
            return

        path = pathlib.Path(self.filename_or_stream)

        if not path.exists():
            print("Can't find " + str(path))
            return

        with path.open(mode='r') as f:
            y = list(yaml.safe_load_all(f))
            if isinstance(y[0], dict) and y[0].get('kind', None) == 'List':
                y = y[0]['items']

        with path.open(mode='w+') as f:
            print('Rewrote: ' + str(path))
            yaml.dump_all(y, f, default_flow_style=False)

    def _add_comment(self, line):
        index = len(self.resources)
        if index in self.comments:
            l = self.comments[index]
        else:
            l = list()
            self.comments[index] = l
        l.append('# ' + line + '\n')

    def add_comments(self, *args):
        for arg in args:
            for line in str(arg).strip().split('\n'):
                self._add_comment(line)

    def append(self, resource, comment=None, caller=None):
        if not caller:
            caller = getframeinfo(stack()[1][0])
        if not isinstance(resource, dict):
            raise IOError('Only expecting dict; received: ' + type(resource))
        if comment:
            self.add_comments(comment)
        self.who[len(self.resources)] = f'{os.path.basename(caller.filename)}'
        self.resources.append(resource)

    def append_all(self, resource_list, comment=None):
        caller = getframeinfo(stack()[1][0])
        for res in resource_list:
            self.append(res, comment=comment, caller=caller)

    def __enter__(self):
        if self.sort_only:
            return self

        if isinstance(self.filename_or_stream, str):
            # It's a filename
            self.stream = open(self.filename_or_stream, mode='w+', encoding='utf-8')
            self.stream.write("##################################################################################\n")
            self.stream.write('#                                DO NOT EDIT\n')
            self.stream.write('# File generated during execution of: ' + os.path.basename(sys.argv[0]) + '\n')
            self.stream.write("##################################################################################\n\n\n")
            self.owns_file = True
        else:
            self.stream = self.filename_or_stream

        return self

    def __exit__(self, *args):
        if self.sort_only:
            return
        if not self.resources:
            raise IOError(f"No resources added to document {str(self.filename_or_stream)}")

        for i, res in enumerate(self.resources):
            if i > 0:
                self.stream.write('---\n')
            self.stream.write("#---------------------------------------------------------------------------------\n")
            self.stream.write(f'# {self.who.get(i)} added the following resource\n')
            self.stream.write("#---------------------------------------------------------------------------------\n\n")
            comments = self.comments.get(i, None)
            if comments:
                self.stream.writelines(comments)
            yaml.safe_dump(res, self.stream, default_flow_style=False, width=float("inf"))

        if self.owns_file:
            self.stream.close()
