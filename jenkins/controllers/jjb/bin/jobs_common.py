import os
from sets import Set

def job_names_file():
    return os.path.join(os.path.expanduser("~"),".known_job_names")

def read_known_names():
    try:
        f = open(job_names_file(), "r")
    except:
        return Set()

    lines = f.readlines()
    names = Set()
    for line in lines:
        line = line.strip()
        if len(line) > 0:
            names.add(line)

    return names

def save_known_names(names):
    with open(job_names_file(), "w") as f:
        for name in names:
            f.write(name)
            f.write("\n")

def add_to_known_names(namespace, name):
    known_names = read_known_names()
    known_names.add("{}/{}".format(namespace,name))
    save_known_names(known_names)

def delete_from_known_names(namespace, name):
    known_names = read_known_names()
    known_names.remove("{}/{}".format(namespace, name))
    save_known_names(known_names)
