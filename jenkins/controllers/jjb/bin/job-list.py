#!/usr/bin/python

import jobs_common

def main():
    names = jobs_common.read_known_names()
    for name in names:
        print(name)


if __name__ == "__main__":
    main()
