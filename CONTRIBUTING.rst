============
Contributing
============

We welcome contributions to ``crystalline``! Please follow these guidelines to make the process smooth for everyone.

Getting Started
===============

#. Fork the repository on GitHub: `<https://github.com/renich/crystalline/fork>`_.
#. Clone your fork locally.
#. Create a new branch for your changes:

   .. code-block:: bash

      git checkout -b feature/my-cool-feature

Development Workflow
====================

#. Install development dependencies:

   .. code-block:: bash

      shards install

#. Make your changes.
#. Format the code. Always run the formatter before committing:

   .. code-block:: bash

      crystal tool format

#. Run tests to ensure everything is functioning correctly:

   .. code-block:: bash

      crystal spec

Commit Guidelines
=================

We use `Conventional Commits <https://www.conventionalcommits.org/>`_. Please format your commit messages as follows:

.. code-block:: text

   type(scope): description

   Body description (optional)

* **Types**: ``feat``, ``fix``, ``docs``, ``style``, ``refactor``, ``perf``, ``test``, ``chore``.
* **Mood**: Use the imperative mood ("add feature" instead of "added feature").

Submitting a Pull Request
=========================

#. Push your branch to GitHub:

   .. code-block:: bash

      git push origin feature/my-cool-feature

#. Open a Pull Request against the ``master`` branch of the main repository.
#. Describe your changes clearly and link to any related issues.
