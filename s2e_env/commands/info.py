from __future__ import print_function

import datetime
import glob
import json
import os

from s2e_env.command import EnvCommand


def _make_date_human_readable(timestamp):
    """
    Make a Unix timestamp human-readable.
    """
    fmt = '%H:%M, %a %d %B %Y'

    return datetime.datetime.fromtimestamp(timestamp).strftime(fmt)


class Command(EnvCommand):
    """
    Displays a summary of the S2E environment.
    """

    help = 'Displays a summary of the S2E environment.'

    def handle(self, **options):
        # Naively check if S2E has been built (by checking some QEMU binaries
        # exist)
        s2e_built = len(glob.glob(self.env_path('bin', 'qemu-system-*'))) > 0

        # Get information on the available images
        images = {}
        for img_path in glob.glob(self.env_path('images', '.*.json')):
            # We only care about the file name, not the extension (first index)
            # Remove the leading '.' from the hidden file
            name = os.path.splitext(os.path.basename(img_path))[0][1:]

            with open(img_path, 'r') as f:
                images[name] = json.load(f)

                # Make creation timestamp human-readable
                create_time = images[name]['creation_time']
                images[name]['creation_time'] = \
                    _make_date_human_readable(create_time)

        # Get information on the available projects
        projects = {}
        for project in os.listdir(self.env_path('projects')):
            json_desc_path = self.env_path('projects', project,
                                           '.project.json')
            with open(json_desc_path, 'r') as f:
                projects[project] = json.load(f)

                # Make creation timestamp human-readable
                create_time = projects[project]['creation_time']
                projects[project]['creation_time'] = \
                    _make_date_human_readable(create_time)

        output = {
            'env_path': self._env_dir,
            's2e_built': s2e_built,
            'images': images,
            'projects': projects,
        }

        print(json.dumps(output, indent=4, sort_keys=True))