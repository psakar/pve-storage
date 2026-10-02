package PVE::API2::Disks::Directory;

use strict;
use warnings;

use POSIX;

use PVE::Diskmanage;
use PVE::InitSystem;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools qw(run_command dir_glob_foreach);

use PVE::API2::Storage::Config;

use base qw(PVE::RESTHandler);

my $SGDISK = '/sbin/sgdisk';
my $MKFS = '/sbin/mkfs';
my $BLKID = '/sbin/blkid';

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    description => "PVE Managed Directory storages.",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                unitfile => {
                    type => 'string',
                    description => 'The path of the mount unit, or of /etc/fstab without'
                        . ' systemd.',
                },
                path => {
                    type => 'string',
                    description => 'The mount path.',
                },
                device => {
                    type => 'string',
                    description => 'The mounted device.',
                },
                type => {
                    type => 'string',
                    description => 'The filesystem type.',
                },
                options => {
                    type => 'string',
                    description => 'The mount options.',
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $result = [];

        for my $mount (PVE::InitSystem::list_mounts('/mnt/pve/')->@*) {
            push @$result,
                {
                    unitfile => $mount->{config},
                    path => $mount->{where},
                    device => $mount->{what},
                    type => $mount->{type},
                    options => $mount->{options},
                };
        }

        return $result;
    },
});

__PACKAGE__->register_method({
    name => 'create',
    path => '',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    permissions => {
        description =>
            "Requires additionally 'Datastore.Allocate' on /storage when setting 'add_storage'",
        check => ['perm', '/', ['Sys.Modify']],
    },
    description =>
        "Create a Filesystem on an unused disk. Will be mounted under '/mnt/pve/NAME'.",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            name => get_standard_option('pve-storage-id'),
            device => {
                type => 'string',
                description => 'The block device you want to create the filesystem on.',
            },
            add_storage => {
                description => "Configure storage using the directory.",
                type => 'boolean',
                optional => 1,
                default => 0,
            },
            filesystem => {
                description => "The desired filesystem.",
                type => 'string',
                enum => ['ext4', 'xfs'],
                optional => 1,
                default => 'ext4',
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $user = $rpcenv->get_user();

        my $name = $param->{name};
        my $dev = $param->{device};
        my $node = $param->{node};
        my $type = $param->{filesystem} // 'ext4';
        my $path = "/mnt/pve/$name";

        $dev = PVE::Diskmanage::verify_blockdev_path($dev);
        PVE::Diskmanage::assert_disk_unused($dev);

        my $storage_params = {
            type => 'dir',
            storage => $name,
            content => 'rootdir,images,iso,backup,vztmpl,snippets',
            is_mountpoint => 1,
            path => $path,
            nodes => $node,
        };
        my $verify_params = [qw(path)];

        if ($param->{add_storage}) {
            $rpcenv->check($user, "/storage", ['Datastore.Allocate']);

            # reserve the name and add as disabled, will be enabled below if creation works out
            PVE::API2::Storage::Config->create_or_update(
                $name, $node, $storage_params, $verify_params, 1,
            );
        }

        my $mounted = PVE::Diskmanage::mounted_paths();
        die "the path for '${name}' is already mounted: ${path} ($mounted->{$path})\n"
            if $mounted->{$path};
        if (my $mount = PVE::InitSystem::get_mount($path)) {
            die "a mount for '${path}' already exists: $mount->{config}\n";
        }

        my $worker = sub {
            PVE::Diskmanage::locked_disk_action(sub {
                PVE::Diskmanage::assert_disk_unused($dev);

                my $part = $dev;

                if (PVE::Diskmanage::is_partition($dev)) {
                    eval { PVE::Diskmanage::change_parttype($dev, '8300'); };
                    warn $@ if $@;
                } else {
                    # create partition
                    my $cmd = [$SGDISK, '-n1', '-t1:8300', $dev];
                    print "# ", join(' ', @$cmd), "\n";
                    run_command($cmd);

                    my ($devname) = $dev =~ m|^/dev/(.*)$|;
                    $part = "/dev/";
                    dir_glob_foreach(
                        "/sys/block/$devname",
                        qr/\Q$devname\E.+/,
                        sub {
                            my ($partition) = @_;
                            $part .= $partition;
                        },
                    );
                }

                # create filesystem
                my $cmd = [$MKFS, '-t', $type, $part];
                print "# ", join(' ', @$cmd), "\n";
                run_command($cmd);

                my $uuid_path;
                my $uuid;

                $cmd = [$BLKID, $part, '-o', 'export'];
                print "# ", join(' ', @$cmd), "\n";
                run_command(
                    $cmd,
                    outfunc => sub {
                        my ($line) = @_;

                        if ($line =~ m/^UUID=(.*)$/) {
                            $uuid = $1;
                            $uuid_path = "/dev/disk/by-uuid/$uuid";
                        }
                    },
                );

                die "could not get UUID of device '$part'\n" if !$uuid;

                PVE::Diskmanage::udevadm_trigger($part);

                # create a persistent mount (a systemd mount unit, or an fstab entry without
                # systemd) and mount it
                PVE::InitSystem::create_mount(
                    where => $path,
                    what => $uuid_path,
                    type => $type,
                    options => 'defaults',
                    description => "Mount storage '$name' under /mnt/pve",
                );

                if ($param->{add_storage}) {
                    PVE::API2::Storage::Config->create_or_update(
                        $name, $node, $storage_params, $verify_params,
                    );
                }
            });
        };

        return $rpcenv->fork_worker('dircreate', $name, $user, $worker);
    },
});

__PACKAGE__->register_method({
    name => 'delete',
    path => '{name}',
    method => 'DELETE',
    proxyto => 'node',
    protected => 1,
    permissions => {
        description =>
            "Requires additionally 'Datastore.Allocate' on /storage when setting 'cleanup-config'",
        check => ['perm', '/', ['Sys.Modify']],
    },
    description => "Unmounts the storage and removes the mount unit.",
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            name => get_standard_option('pve-storage-id'),
            'cleanup-config' => {
                description =>
                    "Marks associated storage(s) as not available on this node anymore "
                    . "or removes them from the configuration (if configured for this node only).",
                type => 'boolean',
                optional => 1,
                default => 0,
            },
            'cleanup-disks' => {
                description => "Also wipe disk so it can be repurposed afterwards.",
                type => 'boolean',
                optional => 1,
                default => 0,
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $user = $rpcenv->get_user();

        $rpcenv->check($user, "/storage", ['Datastore.Allocate']) if $param->{'cleanup-config'};

        my $name = $param->{name};
        my $node = $param->{node};

        my $worker = sub {
            my $path = "/mnt/pve/$name";

            PVE::Diskmanage::locked_disk_action(sub {
                my $to_wipe;
                if ($param->{'cleanup-disks'}) {
                    my $mount = PVE::InitSystem::get_mount($path)
                        or die "no mount for '$path' found\n";

                    my $dev = PVE::Diskmanage::verify_blockdev_path($mount->{what});
                    $to_wipe = $dev;

                    # clean up whole device if this is the only partition
                    $dev =~ s|^/dev/||;
                    my $info = PVE::Diskmanage::get_disks($dev, 1, 1);
                    die "unable to obtain information for disk '$dev'\n" if !$info->{$dev};
                    $to_wipe = $info->{$dev}->{parent}
                        if $info->{$dev}->{parent} && scalar(keys $info->%*) == 2;
                }

                PVE::InitSystem::remove_mount($path);

                my $config_err;
                if ($param->{'cleanup-config'}) {
                    my $match = sub {
                        my ($scfg) = @_;
                        return $scfg->{type} eq 'dir' && $scfg->{path} eq $path;
                    };
                    eval {
                        PVE::API2::Storage::Config->cleanup_storages_for_node($match, $node);
                    };
                    warn $config_err = $@ if $@;
                }

                if ($to_wipe) {
                    PVE::Diskmanage::wipe_blockdev($to_wipe);
                    PVE::Diskmanage::udevadm_trigger($to_wipe);
                }

                die "config cleanup failed - $config_err" if $config_err;
            });
        };

        return $rpcenv->fork_worker('dirremove', $name, $user, $worker);
    },
});

1;
