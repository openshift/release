Name:		golang
Version:	v1.19
Release:	1%{?dist}
Summary:	Go install from source
Group:		Fake
License:	BSD
BuildRoot:	%(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)
Provides:	golang
BuildArch:	noarch
%description
%{summary}
%prep
%setup -c -T
%build
%install
%files
%defattr(-,root,root,-)
%changelog
* Fri Jan 6 2023 Sohan Kunkerkar <skunkerk@redhat.com> 0.0-1
- Initial change
EOF
